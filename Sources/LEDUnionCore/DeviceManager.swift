import Foundation

public enum LEDCommand: Sendable, Equatable {
    case power(Bool)
    case color(RGBColor)
    case brightness(Int)
    case speed(Int)
    case effect(LEDEffect)
    /// White channel level, 0...100.
    case white(Int)
    /// Colour temperature, 0 = cold ... 100 = warm.
    case warmth(Int)
}

public enum DeviceManagerError: Error, LocalizedError, Sendable {
    case unsupported(String)
    case noDevices

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "Контроллер не поддерживает: \(what)"
        case .noDevices: return "Нет сохранённых устройств. Добавьте контроллер в приложении."
        }
    }
}

public enum DeviceManagerEvent: Sendable {
    case phase(UUID, LEDConnectionPhase)
    case devicesChanged
    case bluetooth(BluetoothPowerState)
    case scanning(Bool)
    case discovered(BLEAdvertisement)
    case diagnostic(LEDDiagnosticEvent)
}

/// Owns every controller connection. One instance per process (`LEDRuntime.shared`)
/// serves the SwiftUI app and the App Intents, so Shortcuts reuse a live link
/// instead of racing the app with a second CoreBluetooth manager.
@MainActor
public final class DeviceManager {
    public let transport: BLETransport
    public let store: LEDStore
    public let diagnostics: Diagnostics
    public let automation: AutomationManager
    public let scenes: SceneManager
    public let groups: GroupManager

    public private(set) var phases: [UUID: LEDConnectionPhase] = [:]

    private var queues: [UUID: CommandQueue] = [:]
    private var drivers: [UUID: any LEDProtocolDriver] = [:]
    private var connectTasks: [UUID: Task<Void, Error>] = [:]
    private var reconnectTasks: [UUID: Task<Void, Never>] = [:]
    private var reconnectTokens: [UUID: UUID] = [:]
    /// Devices the user wants connected. Only these are reconnected automatically.
    private var wanted: Set<UUID> = []
    private let broadcaster = EventBroadcaster<DeviceManagerEvent>()
    private var transportTask: Task<Void, Never>?

    public init(transport: BLETransport = BLETransport(), store: LEDStore, diagnostics: Diagnostics = Diagnostics()) {
        self.transport = transport; self.store = store; self.diagnostics = diagnostics
        self.automation = AutomationManager(store: store)
        self.scenes = SceneManager(store: store)
        self.groups = GroupManager(store: store)
        let stream = transport.events()
        transportTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
    }

    public func events() -> AsyncStream<DeviceManagerEvent> { broadcaster.stream() }

    public func phase(for id: UUID) -> LEDConnectionPhase { phases[id] ?? .idle }

    public func isReady(_ id: UUID) -> Bool { phase(for: id).isReady && transport.isReady(id) }

    public func driver(for device: LEDDevice) -> any LEDProtocolDriver {
        drivers[device.id] ?? DriverRegistry.driver(for: device.advertisedName)
    }

    // MARK: Launch

    /// A persisted `connected` flag means nothing after a relaunch. Clear it, then
    /// bring back every device the user left connected.
    public func bootstrap() async {
        try? await store.update { state in
            for index in state.devices.indices { state.devices[index].connected = false }
        }
        let saved = await store.snapshot().devices
        for device in saved where device.wantsAutoConnect {
            wanted.insert(device.id)
            startReconnectLoop(device.id, immediate: true)
        }
        broadcaster.yield(.devicesChanged)
    }

    // MARK: Connecting

    /// User-initiated connect: up to three attempts, then reports the last error.
    public func connect(id: UUID, advertisedName: String) async throws {
        wanted.insert(id)
        reconnectTasks.removeValue(forKey: id)?.cancel()
        try await ensureConnected(id: id, advertisedName: advertisedName, attempts: 3)
    }

    private func ensureConnected(id: UUID, advertisedName: String, attempts: Int, reconnectAttempt: Int? = nil) async throws {
        if isReady(id) { return }
        if let running = connectTasks[id] {
            try await running.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { throw CancellationError() }
            try await self.performConnect(id: id, advertisedName: advertisedName, attempts: attempts, reconnectAttempt: reconnectAttempt)
        }
        connectTasks[id] = task
        defer { if connectTasks[id] == task { connectTasks.removeValue(forKey: id) } }
        try await task.value
    }

    private func performConnect(id: UUID, advertisedName: String, attempts: Int, reconnectAttempt: Int?) async throws {
        let driver = prepareDriver(id: id, advertisedName: advertisedName)
        let profile = BLELinkProfile(serviceUUID: driver.serviceUUID,
                                     writeCharacteristicUUID: driver.writeCharacteristicUUID,
                                     notifyCharacteristicUUID: driver.notifyCharacteristicUUID)
        var lastError: Error = BLETransportError.timeout
        for attempt in 1...max(1, attempts) {
            try Task.checkCancellation()
            do {
                if transport.powerState != .poweredOn { setPhase(id, .waitingForBluetooth) }
                try await transport.waitUntilPoweredOn()
                setPhase(id, reconnectAttempt.map { .reconnecting(attempt: $0) } ?? .connecting(attempt: attempt))
                try await transport.connect(id: id, profile: profile, timeout: .seconds(12))
                setPhase(id, .handshaking)
                try await handshake(id: id, driver: driver)
                setPhase(id, .ready)
                await markConnected(id: id, advertisedName: advertisedName, driver: driver)
                await record(id, "connection", "ready (\(driver.id), attempt \(attempt))")
                return
            } catch let error as BLETransportError where [.poweredOff, .unauthorized, .unsupported, .cancelled].contains(error) {
                setPhase(id, .failed(error.localizedDescription))
                await markDisconnected(id: id)
                throw error
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                await record(id, "connection", "attempt \(attempt) failed: \(error.localizedDescription)")
                transport.disconnect(id: id)
                if attempt < attempts { try await Task.sleep(for: .milliseconds(700 * attempt)) }
            }
        }
        setPhase(id, .failed(lastError.localizedDescription))
        await markDisconnected(id: id)
        throw lastError
    }

    private func prepareDriver(id: UUID, advertisedName: String) -> any LEDProtocolDriver {
        if let driver = drivers[id], queues[id] != nil { return driver }
        let driver = DriverRegistry.driver(for: advertisedName)
        drivers[id] = driver
        let transport = self.transport
        queues[id] = CommandQueue(minimumGap: driver.minimumGap) { @MainActor data in
            let chunkSize = max(1, driver.chunkSize ?? data.count)
            for offset in stride(from: 0, to: data.count, by: chunkSize) {
                let end = min(offset + chunkSize, data.count)
                try await transport.write(id: id, data: Data(data[offset..<end]),
                                          characteristicUUID: driver.writeCharacteristicUUID,
                                          withoutResponse: driver.writeWithoutResponse)
                if end < data.count { try await Task.sleep(for: driver.minimumGap) }
            }
        }
        return driver
    }

    private func handshake(id: UUID, driver: any LEDProtocolDriver) async throws {
        let frames = driver.onConnect(now: .now)
        guard !frames.isEmpty else { return }
        if driver.handshakeDelay > .zero { try await Task.sleep(for: driver.handshakeDelay) }
        for frame in frames { try await write(frame, to: id) }
    }

    public func disconnect(id: UUID) async {
        wanted.remove(id)
        reconnectTasks.removeValue(forKey: id)?.cancel()
        connectTasks.removeValue(forKey: id)?.cancel()
        transport.cancelConnection(id: id)
        setPhase(id, .idle)
        await markDisconnected(id: id)
        await record(id, "connection", "disconnected by user")
    }

    /// Removes the device from the app entirely.
    public func forget(id: UUID) async {
        await disconnect(id: id)
        queues.removeValue(forKey: id)
        drivers.removeValue(forKey: id)
        phases.removeValue(forKey: id)
        try? await store.update { state in
            state.devices.removeAll { $0.id == id }
            for index in state.groups.indices { state.groups[index].deviceIDs.removeAll { $0 == id } }
            for index in state.scenes.indices { state.scenes[index].entries.removeAll { $0.deviceID == id } }
            if state.lastSelectedDeviceID == id { state.lastSelectedDeviceID = nil }
        }
        broadcaster.yield(.devicesChanged)
    }

    public func rename(id: UUID, to label: String) async {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        try? await store.update { state in
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            state.devices[index].label = trimmed.isEmpty ? nil : trimmed
        }
        broadcaster.yield(.devicesChanged)
    }

    public func setAutoConnect(id: UUID, _ enabled: Bool) async {
        try? await store.update { state in
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            state.devices[index].autoConnect = enabled
        }
        broadcaster.yield(.devicesChanged)
    }

    // MARK: Automatic reconnection

    /// Called when the app returns to the foreground: retry wanted devices now
    /// instead of waiting out the backoff.
    public func resume() {
        for id in wanted where !isReady(id) && connectTasks[id] == nil {
            reconnectTasks.removeValue(forKey: id)?.cancel()
            startReconnectLoop(id, immediate: true)
        }
    }

    private func startReconnectLoop(_ id: UUID, immediate: Bool = false) {
        guard reconnectTasks[id] == nil, connectTasks[id] == nil, wanted.contains(id) else { return }
        let token = UUID()
        reconnectTokens[id] = token
        reconnectTasks[id] = Task { @MainActor [weak self] in
            var attempt = 0
            if !immediate { try? await Task.sleep(for: .seconds(1)) }
            while !Task.isCancelled {
                guard let self, self.wanted.contains(id) else { break }
                if self.isReady(id) { break }
                guard let device = await self.savedDevice(id) else { break }
                attempt += 1
                do {
                    try await self.ensureConnected(id: id, advertisedName: device.advertisedName, attempts: 1, reconnectAttempt: attempt)
                    break
                } catch is CancellationError {
                    break
                } catch {
                    guard !Task.isCancelled, self.wanted.contains(id) else { break }
                    self.setPhase(id, .reconnecting(attempt: attempt))
                }
                // 2, 4, 8, 16, 30, 30... seconds between attempts.
                try? await Task.sleep(for: .seconds(min(30, 1 << min(attempt, 5))))
            }
            // A cancelled loop must not unregister the loop that replaced it.
            if let self, self.reconnectTokens[id] == token {
                self.reconnectTasks.removeValue(forKey: id)
                self.reconnectTokens.removeValue(forKey: id)
            }
        }
    }

    private func handle(_ event: BLEEvent) async {
        switch event {
        case .power(let power):
            broadcaster.yield(.bluetooth(power))
            if power == .poweredOn {
                for id in wanted where !isReady(id) {
                    reconnectTasks.removeValue(forKey: id)?.cancel()
                    startReconnectLoop(id, immediate: true)
                }
            } else if power != .unknown {
                for id in wanted where phase(for: id) == .ready { setPhase(id, .waitingForBluetooth) }
            }
        case .scanning(let value):
            broadcaster.yield(.scanning(value))
        case .discovered(let advertisement):
            broadcaster.yield(.discovered(advertisement))
        case .linkPhase(let id, let phase):
            // Transport phases are only interesting while a connect is in flight.
            if connectTasks[id] != nil { setPhase(id, phase) }
        case .disconnected(let id, let message, let expected):
            let wasReady = phase(for: id) == .ready
            await markDisconnected(id: id)
            if connectTasks[id] != nil { return } // the running connect retries itself
            if !expected, wanted.contains(id) {
                await record(id, "connection", "lost: \(message ?? "no reason"), reconnecting")
                setPhase(id, .reconnecting(attempt: 0))
                startReconnectLoop(id)
            } else if wasReady || !expected {
                setPhase(id, .idle)
            }
        case .diagnostic(let event):
            await diagnostics.record(event)
            broadcaster.yield(.diagnostic(event))
        case .state, .connected, .notification:
            break
        }
    }

    // MARK: Commands

    /// Sends one command, connecting or reconnecting first when needed.
    /// `remember: false` skips persisting the look — use it for live slider drags.
    public func send(_ command: LEDCommand, to id: UUID, coalescingKey: String? = nil, remember: Bool = true) async throws {
        guard let device = await savedDevice(id) else { throw BLETransportError.deviceNotFound }
        wanted.insert(id)
        if !isReady(id) {
            reconnectTasks.removeValue(forKey: id)?.cancel()
            try await ensureConnected(id: id, advertisedName: device.advertisedName, attempts: 2)
        }
        let driver = prepareDriver(id: id, advertisedName: device.advertisedName)
        guard let frame = frame(for: command, driver: driver) else {
            throw DeviceManagerError.unsupported(command.title)
        }
        do {
            try await write(frame, to: id, coalescingKey: coalescingKey)
        } catch {
            // The link can drop between the readiness check and the write.
            await record(id, "command", "write failed, reconnecting: \(error.localizedDescription)")
            try await ensureConnected(id: id, advertisedName: device.advertisedName, attempts: 2)
            try await write(frame, to: id, coalescingKey: coalescingKey)
        }
        try? await store.update({ state in
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            switch command {
            case .power(let value): state.devices[index].lastLook.power = value
            case .color(let value):
                state.devices[index].lastLook.color = value
                state.devices[index].lastLook.effect = nil
                state.devices[index].lastLook.power = true
            case .brightness(let value): state.devices[index].lastLook.brightness = value
            case .speed(let value): state.devices[index].lastLook.speed = value
            case .effect(let value):
                state.devices[index].lastLook.effect = value
                state.devices[index].lastLook.power = true
            case .white(let value): state.devices[index].lastLook.white = value
            case .warmth(let value): state.devices[index].lastLook.warmth = value
            }
        }, persist: remember)
        if case .color(let color) = command, remember {
            try? await store.update { state in
                state.history.removeAll { $0 == color }
                state.history.insert(color, at: 0)
                if state.history.count > 12 { state.history.removeLast(state.history.count - 12) }
            }
        }
        if remember { await record(id, "command", command.title) }
    }

    /// Applies a command to several devices in parallel and returns the failures.
    @discardableResult
    public func apply(_ command: LEDCommand, to ids: [UUID], coalescingKey: String? = nil, remember: Bool = true) async -> [UUID: String] {
        let running = ids.map { id in
            (id, Task { @MainActor in try await self.send(command, to: id, coalescingKey: coalescingKey, remember: remember) })
        }
        return await Self.collectFailures(running)
    }

    private static func collectFailures(_ running: [(UUID, Task<Void, Error>)]) async -> [UUID: String] {
        var failures: [UUID: String] = [:]
        for (id, task) in running {
            do { try await task.value } catch { failures[id] = error.localizedDescription }
        }
        return failures
    }

    /// Restores a whole saved look on one controller.
    public func apply(look: LEDLook, to id: UUID) async throws {
        if look.power == false {
            try await send(.power(false), to: id)
            return
        }
        try await send(.power(true), to: id)
        if let effect = look.effect {
            try await send(.effect(effect), to: id)
            if let speed = look.speed { try await send(.speed(speed), to: id) }
        } else if let color = look.color {
            try await send(.color(color), to: id)
        }
        if let brightness = look.brightness { try await send(.brightness(brightness), to: id) }
    }

    @discardableResult
    public func applyScene(_ sceneID: UUID) async throws -> [UUID: String] {
        guard let scene = await store.snapshot().scenes.first(where: { $0.id == sceneID }) else {
            throw BLETransportError.deviceNotFound
        }
        let running = scene.entries.map { entry in
            (entry.deviceID, Task { @MainActor in try await self.apply(look: entry.look, to: entry.deviceID) })
        }
        return await Self.collectFailures(running)
    }

    /// Compatibility path for the Svelte protocol builders and diagnostics.
    public func sendRaw(_ frame: Data, to id: UUID, coalescingKey: String? = nil) async throws {
        guard let device = await savedDevice(id) else { throw BLETransportError.deviceNotFound }
        if !isReady(id) { try await ensureConnected(id: id, advertisedName: device.advertisedName, attempts: 2) }
        try await write(frame, to: id, coalescingKey: coalescingKey)
        await record(id, "raw-command", frame.map { String(format: "%02x", $0) }.joined(separator: " "))
    }

    public func reconnectSavedDevices() async {
        let saved = await store.snapshot().devices
        for device in saved where !isReady(device.id) {
            try? await connect(id: device.id, advertisedName: device.advertisedName)
        }
    }

    public func persist() async { try? await store.save() }

    // MARK: Helpers

    private func frame(for command: LEDCommand, driver: any LEDProtocolDriver) -> Data? {
        switch command {
        case .power(let on): return driver.power(on)
        case .color(let color): return driver.rgb(color)
        case .brightness(let percent): return driver.brightness(percent)
        case .speed(let percent): return driver.speed(percent)
        case .effect(let effect): return driver.effect(effect)
        case .white(let percent): return driver.white(percent)
        case .warmth(let warm): return driver.cct(warm: warm, cool: 100 - max(0, min(100, warm)))
        }
    }

    private func write(_ frame: Data, to id: UUID, coalescingKey: String? = nil) async throws {
        guard let queue = queues[id] else { throw BLETransportError.disconnected }
        let before = await queue.snapshot().failed
        await queue.enqueue(frame, coalescingKey: coalescingKey)
        await queue.waitUntilIdle()
        let result = await queue.snapshot()
        if result.failed > before { throw CommandQueueError.writeFailed(result.lastError ?? "unknown error") }
    }

    private func savedDevice(_ id: UUID) async -> LEDDevice? {
        await store.snapshot().devices.first { $0.id == id }
    }

    private func setPhase(_ id: UUID, _ phase: LEDConnectionPhase) {
        guard phases[id] != phase else { return }
        phases[id] = phase
        broadcaster.yield(.phase(id, phase))
    }

    private func markConnected(id: UUID, advertisedName: String, driver: any LEDProtocolDriver) async {
        try? await store.update { state in
            if let index = state.devices.firstIndex(where: { $0.id == id }) {
                state.devices[index].connected = true
                state.devices[index].driverID = driver.id
                state.devices[index].capabilities = driver.capabilities
                state.devices[index].lastConnectedAt = .now
            } else {
                state.devices.append(LEDDevice(id: id, advertisedName: advertisedName, driverID: driver.id,
                                               capabilities: driver.capabilities, connected: true,
                                               autoConnect: true, lastConnectedAt: .now))
            }
        }
        broadcaster.yield(.devicesChanged)
    }

    private func markDisconnected(id: UUID) async {
        let changed = (await store.snapshot().devices.first { $0.id == id })?.connected == true
        guard changed else { return }
        try? await store.update { state in
            if let index = state.devices.firstIndex(where: { $0.id == id }) { state.devices[index].connected = false }
        }
        broadcaster.yield(.devicesChanged)
    }

    private func record(_ id: UUID?, _ kind: String, _ detail: String) async {
        let event = LEDDiagnosticEvent(deviceID: id, kind: kind, detail: detail)
        await diagnostics.record(event)
        broadcaster.yield(.diagnostic(event))
    }
}

public extension LEDCommand {
    var title: String {
        switch self {
        case .power(let on): return on ? "включение" : "выключение"
        case .color(let color): return "цвет \(color.hex)"
        case .brightness(let value): return "яркость \(value)%"
        case .speed(let value): return "скорость \(value)%"
        case .effect(let effect): return "эффект \(effect.name)"
        case .white(let value): return "белый \(value)%"
        case .warmth(let value): return "температура \(value)%"
        }
    }
}

/// The single process-wide runtime shared by the SwiftUI scene and App Intents.
@MainActor
public final class LEDRuntime {
    // Lazily created instead of a `static let` initializer: Release builds of the
    // App Intents target previously crashed in a global initializer.
    private static var instance: LEDRuntime?
    public static var shared: LEDRuntime {
        if let instance { return instance }
        let runtime = LEDRuntime()
        instance = runtime
        return runtime
    }

    public let store: LEDStore
    public let manager: DeviceManager
    private var bootTask: Task<Void, Never>?

    private init() {
        store = (try? LEDStore.applicationSupport())
            ?? LEDStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("led-union.json"))
        manager = DeviceManager(store: store)
    }

    /// Loads the store and starts auto-connect once; later calls just wait for it.
    public func start() async {
        if let bootTask { return await bootTask.value }
        let store = self.store
        let manager = self.manager
        let task = Task { @MainActor in
            try? await store.load()
            await manager.bootstrap()
        }
        bootTask = task
        await task.value
    }
}
