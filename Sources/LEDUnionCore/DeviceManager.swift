import Foundation

public enum LEDCommand: Sendable {
    case power(Bool)
    case color(RGBColor)
    case brightness(Int)
    case speed(Int)
    case effect(LEDEffect)
}

@MainActor
public final class DeviceManager {
    public let transport: BLETransport
    public let store: LEDStore
    public let diagnostics: Diagnostics
    public let automation: AutomationManager
    public let scenes: SceneManager
    public let groups: GroupManager
    private var queues: [UUID: CommandQueue] = [:]
    private var drivers: [UUID: any LEDProtocolDriver] = [:]

    public init(transport: BLETransport = BLETransport(), store: LEDStore, diagnostics: Diagnostics = Diagnostics()) {
        self.transport = transport; self.store = store; self.diagnostics = diagnostics
        self.automation = AutomationManager(store: store)
        self.scenes = SceneManager(store: store)
        self.groups = GroupManager(store: store)
    }

    public func connect(id: UUID, advertisedName: String) async throws {
        let driver = DriverRegistry.driver(for: advertisedName)
        drivers[id] = driver
        if queues[id] == nil {
            queues[id] = CommandQueue(minimumGap: driver.minimumGap) { @MainActor [weak transport] data in
                let chunkSize = driver.chunkSize ?? data.count
                for offset in stride(from: 0, to: data.count, by: chunkSize) {
                    let end = min(offset + chunkSize, data.count)
                    let chunk = Data(data[offset..<end])
                    guard let transport else { throw BLETransportError.disconnected }
                    try transport.write(id: id, data: chunk, characteristicUUID: driver.writeCharacteristicUUID, withoutResponse: driver.writeWithoutResponse)
                    if end < data.count { try? await Task.sleep(for: driver.minimumGap) }
                }
            }
        }
        try await transport.connect(id: id, expectedWriteCharacteristicUUID: driver.writeCharacteristicUUID)
        if let queue = queues[id] {
            for frame in driver.onConnect(now: .now) { await queue.enqueue(frame) }
            await queue.waitUntilIdle()
            let result = await queue.snapshot()
            if result.failed > 0 { throw CommandQueueError.writeFailed(result.lastError ?? "unknown error") }
        }
        try await store.update { state in
            if let index = state.devices.firstIndex(where: { $0.id == id }) {
                state.devices[index].connected = true
            } else {
                state.devices.append(LEDDevice(id: id, advertisedName: advertisedName, driverID: driver.id, capabilities: driver.capabilities, connected: true))
            }
        }
        await diagnostics.record(.init(deviceID: id, kind: "connection", detail: "connected"))
    }

    public func disconnect(id: UUID) async {
        transport.disconnect(id: id)
        try? await store.update { state in
            if let index = state.devices.firstIndex(where: { $0.id == id }) { state.devices[index].connected = false }
        }
        await diagnostics.record(.init(deviceID: id, kind: "connection", detail: "disconnected"))
    }

    public func send(_ command: LEDCommand, to id: UUID, coalescingKey: String? = nil) async throws {
        if queues[id] == nil {
            guard let saved = (await store.snapshot()).devices.first(where: { $0.id == id }) else { throw BLETransportError.deviceNotFound }
            try await connect(id: id, advertisedName: saved.advertisedName)
        }
        guard let driver = drivers[id] else { throw BLETransportError.deviceNotFound }
        guard let queue = queues[id] else { throw BLETransportError.disconnected }
        let frame: Data
        switch command {
        case .power(let on): frame = driver.power(on)
        case .color(let color): frame = driver.rgb(color)
        case .brightness(let percent): frame = driver.brightness(percent)
        case .speed(let percent): frame = driver.speed(percent)
        case .effect(let effect): frame = driver.effect(effect)
        }
        let before = await queue.snapshot().failed
        await queue.enqueue(frame, coalescingKey: coalescingKey)
        await queue.waitUntilIdle()
        let result = await queue.snapshot()
        if result.failed > before { throw CommandQueueError.writeFailed(result.lastError ?? "unknown error") }
        try await store.update { state in
            guard let index = state.devices.firstIndex(where: { $0.id == id }) else { return }
            switch command {
            case .power(let value): state.devices[index].lastLook.power = value
            case .color(let value): state.devices[index].lastLook.color = value
            case .brightness(let value): state.devices[index].lastLook.brightness = value
            case .speed(let value): state.devices[index].lastLook.speed = value
            case .effect(let value): state.devices[index].lastLook.effect = value
            }
        }
        await diagnostics.record(.init(deviceID: id, kind: "command", detail: String(describing: command)))
    }

    /// Compatibility path for the existing Svelte protocol builders and the
    /// diagnostics screen. The bytes still pass through the native per-device queue;
    /// product controls should use `send(_:to:)` whenever a typed command exists.
    public func sendRaw(_ frame: Data, to id: UUID, coalescingKey: String? = nil) async throws {
        if queues[id] == nil {
            guard let saved = (await store.snapshot()).devices.first(where: { $0.id == id }) else { throw BLETransportError.deviceNotFound }
            try await connect(id: id, advertisedName: saved.advertisedName)
        }
        guard let queue = queues[id] else { throw BLETransportError.disconnected }
        let before = await queue.snapshot().failed
        await queue.enqueue(frame, coalescingKey: coalescingKey)
        await queue.waitUntilIdle()
        let result = await queue.snapshot()
        if result.failed > before { throw CommandQueueError.writeFailed(result.lastError ?? "unknown error") }
        await diagnostics.record(.init(deviceID: id, kind: "raw-command", detail: frame.map { String(format: "%02x", $0) }.joined(separator: " ")))
    }

    public func apply(_ command: LEDCommand, to ids: [UUID]) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { try? await self.send(command, to: id, coalescingKey: "\(id.uuidString):\(String(describing: command))") } }
        }
    }

    public func reconnectSavedDevices() async {
        let state = await store.snapshot()
        let saved = state.devices
        for device in saved where !device.connected { try? await connect(id: device.id, advertisedName: device.advertisedName) }
    }
}
