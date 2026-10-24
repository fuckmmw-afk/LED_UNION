import Foundation
#if os(iOS) && canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public enum BLETransportError: Error, LocalizedError, Sendable, Equatable {
    case unavailable
    case poweredOff
    case unauthorized
    case unsupported
    case deviceNotFound
    case serviceNotFound
    case characteristicNotFound
    case disconnected
    case timeout
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Bluetooth недоступен"
        case .poweredOff: return "Bluetooth выключен. Включите его в Пункте управления."
        case .unauthorized: return "Нет доступа к Bluetooth. Разрешите его в Настройках → LED Union."
        case .unsupported: return "Это устройство не поддерживает Bluetooth LE"
        case .deviceNotFound: return "Контроллер не найден. Он включён и рядом?"
        case .serviceNotFound: return "Контроллер не отдал нужный GATT-сервис"
        case .characteristicNotFound: return "У контроллера нет характеристики для записи"
        case .disconnected: return "Связь с контроллером потеряна"
        case .timeout: return "Контроллер не ответил вовремя"
        case .cancelled: return "Подключение отменено"
        }
    }
}

/// Bluetooth radio state as the UI needs to explain it.
public enum BluetoothPowerState: String, Codable, Sendable {
    case unknown, poweredOn, poweredOff, unauthorized, unsupported, resetting
}

/// What the GATT layer needs to know about a driver to call a link usable.
public struct BLELinkProfile: Sendable, Hashable {
    public let serviceUUID: String
    public let writeCharacteristicUUID: String
    public let notifyCharacteristicUUID: String?
    public init(serviceUUID: String, writeCharacteristicUUID: String, notifyCharacteristicUUID: String?) {
        self.serviceUUID = serviceUUID
        self.writeCharacteristicUUID = writeCharacteristicUUID
        self.notifyCharacteristicUUID = notifyCharacteristicUUID
    }
}

public enum BLEEvent: Sendable {
    case state(LEDTransportState)
    case power(BluetoothPowerState)
    case scanning(Bool)
    case discovered(BLEAdvertisement)
    case linkPhase(UUID, LEDConnectionPhase)
    case connected(UUID)
    /// `expected` is true when this app asked for the disconnect.
    case disconnected(UUID, String?, expected: Bool)
    case notification(UUID, Data)
    case diagnostic(LEDDiagnosticEvent)
}

/// CoreBluetooth may report a Bluetooth SIG 16-bit UUID as `FFF3`, while a
/// driver stores the equivalent expanded UUID. Keep both representations
/// comparable without changing the protocol declarations.
func canonicalBluetoothUUID(_ value: String) -> String {
    let lowercased = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let baseSuffix = "-0000-1000-8000-00805f9b34fb"
    if lowercased.count == 4 { return lowercased }
    if lowercased.hasPrefix("0000"), lowercased.hasSuffix(baseSuffix), lowercased.count == 36 {
        return String(lowercased.dropFirst(4).dropLast(baseSuffix.count))
    }
    return lowercased
}

/// Fan-out for transport events: the UI, the device manager and the App Intents
/// all listen to the same CoreBluetooth instance.
@MainActor
final class EventBroadcaster<Event: Sendable> {
    private var continuations: [UUID: AsyncStream<Event>.Continuation] = [:]

    func stream() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Event>.makeStream(bufferingPolicy: .bufferingNewest(256))
        continuations[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.continuations.removeValue(forKey: id) }
        }
        return stream
    }

    func yield(_ event: Event) {
        for continuation in continuations.values { continuation.yield(event) }
    }
}

#if os(iOS) && canImport(CoreBluetooth)
/// CoreBluetooth is isolated to the main actor. There is exactly one instance per
/// process (see `LEDRuntime`), because two central managers sharing a restoration
/// identifier fight over the same peripherals.
@MainActor
public final class BLETransport: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, @unchecked Sendable {
    public let restorationIdentifier: String
    public private(set) var state: LEDTransportState = .idle
    public private(set) var powerState: BluetoothPowerState = .unknown
    public private(set) var isScanning = false
    public private(set) var advertisements: [UUID: BLEAdvertisement] = [:]

    private var central: CBCentralManager!
    private let broadcaster = EventBroadcaster<BLEEvent>()
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var profiles: [UUID: BLELinkProfile] = [:]
    private var writeCharacteristics: [UUID: CBCharacteristic] = [:]
    private var pendingServiceDiscovery: [UUID: Int] = [:]
    private var connectionWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var connectionTimeouts: [UUID: Task<Void, Never>] = [:]
    private var expectedDisconnects: Set<UUID> = []
    private var powerWaiters: [CheckedContinuation<Void, Error>] = []
    private var writeReadyWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var scanRequested = false

    public init(restorationIdentifier: String = "fun.fuckmmw.ledunion.ble") {
        self.restorationIdentifier = restorationIdentifier
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [
            CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier,
            CBCentralManagerOptionShowPowerAlertKey: true,
        ])
    }

    public func events() -> AsyncStream<BLEEvent> { broadcaster.stream() }

    public func isReady(_ id: UUID) -> Bool {
        guard let peripheral = peripherals[id], peripheral.state == .connected else { return false }
        return writeCharacteristics[id] != nil
    }

    public func isLinked(_ id: UUID) -> Bool {
        peripherals[id]?.state == .connected
    }

    // MARK: Power

    /// Suspends until CoreBluetooth reports `.poweredOn`. A cold launch starts in
    /// `.unknown` for a moment, and the permission prompt holds it there longer.
    public func waitUntilPoweredOn(timeout: Duration = .seconds(10)) async throws {
        switch central.state {
        case .poweredOn: return
        case .poweredOff: throw BLETransportError.poweredOff
        case .unauthorized: throw BLETransportError.unauthorized
        case .unsupported: throw BLETransportError.unsupported
        default: break
        }
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self else { return }
            let waiters = self.powerWaiters
            self.powerWaiters.removeAll()
            waiters.forEach { $0.resume(throwing: BLETransportError.unavailable) }
        }
        defer { timeoutTask.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            powerWaiters.append(continuation)
        }
    }

    private func resolvePowerWaiters() {
        let error: BLETransportError?
        switch central.state {
        case .poweredOn: error = nil
        case .poweredOff: error = .poweredOff
        case .unauthorized: error = .unauthorized
        case .unsupported: error = .unsupported
        default: return
        }
        let waiters = powerWaiters
        powerWaiters.removeAll()
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    // MARK: Scanning

    public func startScan() {
        scanRequested = true
        advertisements.removeAll()
        setScanning(true)
        // Keep the request pending until CoreBluetooth reports .poweredOn instead
        // of failing on a cold launch or just after the permission prompt.
        beginScan()
    }

    public func stopScan() {
        scanRequested = false
        if central.state == .poweredOn { central.stopScan() }
        setScanning(false)
    }

    private func setScanning(_ value: Bool) {
        guard isScanning != value else { return }
        isScanning = value
        emit(.scanning(value))
        if value { setState(.scanning) } else if state == .scanning { setState(.idle) }
    }

    private func beginScan() {
        guard scanRequested, central.state == .poweredOn else { return }
        // Many controllers do not put their GATT service in the advertisement, so
        // scan everything and filter by the advertised name. Duplicates keep RSSI live.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    // MARK: Connecting

    /// Connects and resolves the driver's write characteristic. Throws instead of
    /// hanging: CoreBluetooth itself never times a connection attempt out.
    public func connect(id: UUID, profile: BLELinkProfile, timeout: Duration = .seconds(15)) async throws {
        try await waitUntilPoweredOn()
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
            throw BLETransportError.deviceNotFound
        }
        peripherals[id] = peripheral
        peripheral.delegate = self
        profiles[id] = profile
        expectedDisconnects.remove(id)
        if peripheral.state == .connected, writeCharacteristics[id] != nil { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let alreadyWaiting = connectionWaiters[id] != nil
            connectionWaiters[id, default: []].append(continuation)
            guard !alreadyWaiting else { return }
            armTimeout(for: id, timeout: timeout)
            if peripheral.state == .connected {
                phase(id, .discovering)
                discover(peripheral)
            } else {
                setState(.connecting)
                central.connect(peripheral, options: nil)
            }
        }
    }

    public func cancelConnection(id: UUID) {
        finishConnection(id, error: BLETransportError.cancelled)
        disconnect(id: id)
    }

    public func disconnect(id: UUID) {
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { return }
        expectedDisconnects.insert(id)
        if peripheral.state == .disconnected {
            expectedDisconnects.remove(id)
            return
        }
        central.cancelPeripheralConnection(peripheral)
    }

    private func armTimeout(for id: UUID, timeout: Duration) {
        connectionTimeouts[id]?.cancel()
        connectionTimeouts[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.connectionWaiters[id] != nil else { return }
            self.diagnostic(id, "connection", "timeout after \(timeout)")
            self.finishConnection(id, error: BLETransportError.timeout)
            // Drop the pending attempt so the radio is free for the retry.
            if let peripheral = self.peripherals[id] {
                self.expectedDisconnects.insert(id)
                self.central.cancelPeripheralConnection(peripheral)
            }
        }
    }

    private func discover(_ peripheral: CBPeripheral) {
        peripheral.delegate = self
        // nil discovers every service; some firmwares hide the LED service behind a
        // different primary service list than the advertisement suggests.
        peripheral.discoverServices(nil)
    }

    private func finishConnection(_ id: UUID, error: Error? = nil) {
        connectionTimeouts.removeValue(forKey: id)?.cancel()
        let waiters = connectionWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
        guard !waiters.isEmpty else { return }
        setState(error == nil ? .connected : .failed)
    }

    // MARK: Writing

    public func write(id: UUID, data: Data, characteristicUUID: String, withoutResponse: Bool) async throws {
        guard let peripheral = peripherals[id], peripheral.state == .connected else { throw BLETransportError.disconnected }
        guard let characteristic = writeCharacteristic(for: id, uuid: characteristicUUID) else {
            throw BLETransportError.characteristicNotFound
        }
        let canWriteWithoutResponse = characteristic.properties.contains(.writeWithoutResponse)
        let type: CBCharacteristicWriteType = (withoutResponse && canWriteWithoutResponse) || !characteristic.properties.contains(.write)
            ? .withoutResponse
            : .withResponse
        if type == .withoutResponse, !peripheral.canSendWriteWithoutResponse {
            // The radio's buffer is full; writing now silently drops the frame.
            await waitUntilWritable(id, timeout: .milliseconds(500))
            guard peripheral.state == .connected else { throw BLETransportError.disconnected }
        }
        peripheral.writeValue(data, for: characteristic, type: type)
    }

    /// The characteristic resolved at connect time: the driver's documented one, or
    /// the logged fallback when the firmware exposes it under another UUID.
    private func writeCharacteristic(for id: UUID, uuid: String) -> CBCharacteristic? {
        writeCharacteristics[id]
    }

    private func waitUntilWritable(_ id: UUID, timeout: Duration) async {
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.resumeWriteWaiters(id)
        }
        defer { timer.cancel() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writeReadyWaiters[id, default: []].append(continuation)
        }
    }

    private func resumeWriteWaiters(_ id: UUID) {
        let waiters = writeReadyWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0.resume() }
    }

    // MARK: Events

    private func emit(_ event: BLEEvent) { broadcaster.yield(event) }
    private func phase(_ id: UUID, _ phase: LEDConnectionPhase) { emit(.linkPhase(id, phase)) }
    private func setState(_ next: LEDTransportState) {
        state = next
        emit(.state(next))
    }
    private func diagnostic(_ id: UUID?, _ kind: String, _ detail: String) {
        emit(.diagnostic(.init(deviceID: id, kind: kind, detail: detail)))
    }

    // MARK: CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let next: BluetoothPowerState
        switch central.state {
        case .poweredOn: next = .poweredOn
        case .poweredOff: next = .poweredOff
        case .unauthorized: next = .unauthorized
        case .unsupported: next = .unsupported
        case .resetting: next = .resetting
        default: next = .unknown
        }
        powerState = next
        emit(.power(next))
        diagnostic(nil, "bluetooth", next.rawValue)
        resolvePowerWaiters()
        switch central.state {
        case .poweredOn:
            beginScan()
        case .poweredOff, .resetting, .unauthorized, .unsupported:
            // Every link is gone; tell the waiters now instead of at their timeout.
            for id in Array(connectionWaiters.keys) { finishConnection(id, error: BLETransportError.poweredOff) }
            for id in Array(writeCharacteristics.keys) {
                writeCharacteristics.removeValue(forKey: id)
                emit(.disconnected(id, BLETransportError.poweredOff.errorDescription, expected: false))
            }
            setScanning(false)
            setState(.failed)
        default:
            break
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for peripheral in restored {
            peripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            diagnostic(peripheral.identifier, "restore", "state \(peripheral.state.rawValue)")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if peripherals[peripheral.identifier] == nil { peripherals[peripheral.identifier] = peripheral }
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        // Prefer the current advertisement name over CoreBluetooth's cached
        // peripheral.name. The cache can be generic or stale after a firmware
        // rename, while the local-name field is what the controller is airing now.
        let name = [localName, peripheral.name, advertisements[peripheral.identifier]?.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Unknown LED"
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let rssi = RSSI.intValue == 127 ? (advertisements[peripheral.identifier]?.rssi ?? -100) : RSSI.intValue
        let advertisement = BLEAdvertisement(id: peripheral.identifier, name: name, rssi: rssi, serviceUUIDs: serviceUUIDs)
        let previous = advertisements[peripheral.identifier]
        advertisements[peripheral.identifier] = advertisement
        // Only forward meaningful changes; duplicates arrive many times a second.
        if previous == nil || previous?.name != name || abs((previous?.rssi ?? 0) - rssi) >= 4 {
            emit(.discovered(advertisement))
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let id = peripheral.identifier
        diagnostic(id, "connection", "link up, discovering services")
        emit(.connected(id))
        phase(id, .discovering)
        writeCharacteristics.removeValue(forKey: id)
        discover(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        diagnostic(id, "connection", "failed: \(error?.localizedDescription ?? "unknown")")
        finishConnection(id, error: error ?? BLETransportError.disconnected)
        emit(.disconnected(id, error?.localizedDescription, expected: expectedDisconnects.remove(id) != nil))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let id = peripheral.identifier
        writeCharacteristics.removeValue(forKey: id)
        pendingServiceDiscovery.removeValue(forKey: id)
        resumeWriteWaiters(id)
        let expected = expectedDisconnects.remove(id) != nil
        diagnostic(id, "connection", "disconnected\(expected ? "" : " unexpectedly"): \(error?.localizedDescription ?? "no error")")
        finishConnection(id, error: error ?? BLETransportError.disconnected)
        if state == .connected, writeCharacteristics.isEmpty { setState(.disconnected) }
        emit(.disconnected(id, error?.localizedDescription, expected: expected))
    }

    // MARK: CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let id = peripheral.identifier
        if let error {
            diagnostic(id, "gatt", "services: \(error.localizedDescription)")
            finishConnection(id, error: error)
            return
        }
        let services = peripheral.services ?? []
        diagnostic(id, "gatt", "services: \(services.map(\.uuid.uuidString).joined(separator: ", "))")
        guard !services.isEmpty else {
            finishConnection(id, error: BLETransportError.serviceNotFound)
            return
        }
        pendingServiceDiscovery[id] = services.count
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let id = peripheral.identifier
        let remaining = max(0, (pendingServiceDiscovery[id] ?? 1) - 1)
        pendingServiceDiscovery[id] = remaining
        if let error {
            diagnostic(id, "gatt", "\(service.uuid.uuidString): \(error.localizedDescription)")
        } else {
            let listed = (service.characteristics ?? []).map { "\($0.uuid.uuidString) [\($0.properties.rawValue)]" }
            diagnostic(id, "gatt", "\(service.uuid.uuidString): \(listed.joined(separator: ", "))")
        }
        let profile = profiles[id]
        let wantedWrite = profile.map { canonicalBluetoothUUID($0.writeCharacteristicUUID) }
        let wantedNotify = profile?.notifyCharacteristicUUID.map(canonicalBluetoothUUID)
        let wantedService = profile.map { canonicalBluetoothUUID($0.serviceUUID) }
        for characteristic in service.characteristics ?? [] {
            let uuid = canonicalBluetoothUUID(characteristic.uuid.uuidString)
            let writable = characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse)
            if writable, uuid == wantedWrite {
                writeCharacteristics[id] = characteristic
            }
            if uuid == wantedNotify, characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        if writeCharacteristics[id] != nil {
            pendingServiceDiscovery.removeValue(forKey: id)
            phase(id, .linked)
            finishConnection(id)
            return
        }
        guard remaining == 0 else { return }
        pendingServiceDiscovery.removeValue(forKey: id)
        // The documented characteristic is missing. Fall back to a writable one in
        // the driver's service, then to any writable one, and say so in diagnostics.
        let all = (peripheral.services ?? []).flatMap { svc in (svc.characteristics ?? []).map { (svc, $0) } }
        let writable = all.filter { $0.1.properties.contains(.write) || $0.1.properties.contains(.writeWithoutResponse) }
        let fallback = writable.first { canonicalBluetoothUUID($0.0.uuid.uuidString) == wantedService }?.1
        if let fallback {
            diagnostic(id, "gatt", "write characteristic \(wantedWrite ?? "?") missing, using \(fallback.uuid.uuidString)")
            writeCharacteristics[id] = fallback
            phase(id, .linked)
            finishConnection(id)
        } else {
            finishConnection(id, error: writable.isEmpty ? BLETransportError.characteristicNotFound : BLETransportError.serviceNotFound)
        }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        resumeWriteWaiters(peripheral.identifier)
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { diagnostic(peripheral.identifier, "write", error.localizedDescription) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value { emit(.notification(peripheral.identifier, data)) }
        if let error { diagnostic(peripheral.identifier, "notify", error.localizedDescription) }
    }
}
#else
/// Host-test fallback. iOS builds always take the CoreBluetooth implementation
/// above; this keeps pure frame/queue/store tests runnable on a non-Apple host.
@MainActor
public final class BLETransport: @unchecked Sendable {
    public let restorationIdentifier: String
    public private(set) var state: LEDTransportState = .idle
    public private(set) var powerState: BluetoothPowerState = .unsupported
    public private(set) var isScanning = false
    public private(set) var advertisements: [UUID: BLEAdvertisement] = [:]
    private let broadcaster = EventBroadcaster<BLEEvent>()
    public init(restorationIdentifier: String = "fun.fuckmmw.ledunion.ble") { self.restorationIdentifier = restorationIdentifier }
    public func events() -> AsyncStream<BLEEvent> { broadcaster.stream() }
    public func isReady(_ id: UUID) -> Bool { false }
    public func isLinked(_ id: UUID) -> Bool { false }
    public func waitUntilPoweredOn(timeout: Duration = .seconds(10)) async throws { throw BLETransportError.unsupported }
    public func startScan() { state = .failed }
    public func stopScan() { state = .idle }
    public func connect(id: UUID, profile: BLELinkProfile, timeout: Duration = .seconds(15)) async throws { throw BLETransportError.unsupported }
    public func cancelConnection(id: UUID) {}
    public func disconnect(id: UUID) {}
    public func write(id: UUID, data: Data, characteristicUUID: String, withoutResponse: Bool) async throws { throw BLETransportError.unsupported }
}
#endif
