import Foundation
#if os(iOS) && canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif

public enum BLETransportError: Error, LocalizedError, Sendable {
    case unavailable
    case deviceNotFound
    case serviceNotFound
    case characteristicNotFound
    case disconnected
    case timeout

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "Bluetooth is unavailable or permission was denied"
        case .deviceNotFound: return "Bluetooth device is no longer known"
        case .serviceNotFound: return "The controller did not expose a supported GATT service"
        case .characteristicNotFound: return "The controller did not expose a writable characteristic"
        case .disconnected: return "The Bluetooth connection was lost"
        case .timeout: return "Bluetooth operation timed out"
        }
    }
}

public enum BLEEvent: Sendable {
    case state(LEDTransportState)
    case discovered(BLEAdvertisement)
    case connected(UUID)
    case disconnected(UUID, String?)
    case notification(UUID, Data)
    case diagnostic(LEDDiagnosticEvent)
}

/// CoreBluetooth is deliberately isolated to the main actor. The rest of the
/// application only sees Sendable values and async methods, which keeps the
/// Capacitor/WebView boundary independent of delegate lifetime details.
#if os(iOS) && canImport(CoreBluetooth)
@MainActor
public final class BLETransport: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate, @unchecked Sendable {
    public let restorationIdentifier: String
    public private(set) var state: LEDTransportState = .idle
    public private(set) var advertisements: [UUID: BLEAdvertisement] = [:]

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [UUID: CBCharacteristic] = [:]
    private var connectionWaiters: [UUID: [CheckedContinuation<Void, Error>]] = [:]
    private var streamContinuation: AsyncStream<BLEEvent>.Continuation?
    private var services: [CBUUID]

    public init(restorationIdentifier: String = "fun.fuckmmw.ledunion.ble") {
        self.restorationIdentifier = restorationIdentifier
        self.services = [CBUUID(string: DriverRegistry.serviceFFF0), CBUUID(string: DriverRegistry.serviceFFE0)]
        super.init()
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionRestoreIdentifierKey: restorationIdentifier])
    }

    public func events() -> AsyncStream<BLEEvent> {
        AsyncStream { continuation in
            streamContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.streamContinuation = nil }
            }
        }
    }

    public func startScan() {
        guard central.state == .poweredOn else { emit(.state(.failed)); return }
        state = .scanning
        emit(.state(.scanning))
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    public func stopScan() {
        central.stopScan()
        state = .idle
        emit(.state(.idle))
    }

    public func connect(id: UUID) async throws {
        guard let peripheral = peripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else { throw BLETransportError.deviceNotFound }
        peripherals[id] = peripheral
        if peripheral.state == .connected { return }
        state = .connecting; emit(.state(.connecting))
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connectionWaiters[id, default: []].append(continuation)
            central.connect(peripheral, options: nil)
        }
    }

    public func disconnect(id: UUID) {
        guard let peripheral = peripherals[id] else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    public func write(id: UUID, data: Data, characteristicUUID: String, withoutResponse: Bool) throws {
        guard let peripheral = peripherals[id], peripheral.state == .connected else { throw BLETransportError.disconnected }
        guard let characteristic = characteristics[id] else { throw BLETransportError.characteristicNotFound }
        guard characteristic.uuid.uuidString.lowercased() == characteristicUUID.lowercased() else { throw BLETransportError.characteristicNotFound }
        peripheral.writeValue(data, for: characteristic, type: withoutResponse ? .withoutResponse : .withResponse)
    }

    private func emit(_ event: BLEEvent) { streamContinuation?.yield(event) }
    private func resolveCharacteristics(for peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices(services)
    }

    private func finishConnection(_ id: UUID, error: Error? = nil) {
        let waiters = connectionWaiters.removeValue(forKey: id) ?? []
        if let error { waiters.forEach { $0.resume(throwing: error) } }
        else { waiters.forEach { $0.resume() } }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let next: LEDTransportState = central.state == .poweredOn ? .idle : .failed
        state = next; emit(.state(next))
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]) ?? []
        for peripheral in restored { peripherals[peripheral.identifier] = peripheral; resolveCharacteristics(for: peripheral) }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        peripherals[peripheral.identifier] = peripheral
        let name = peripheral.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? "Unknown LED"
        let serviceUUIDs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []).map(\.uuidString)
        let advertisement = BLEAdvertisement(id: peripheral.identifier, name: name, rssi: RSSI.intValue, serviceUUIDs: serviceUUIDs)
        advertisements[peripheral.identifier] = advertisement
        emit(.discovered(advertisement))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .connected; emit(.connected(peripheral.identifier)); resolveCharacteristics(for: peripheral)
        // The controller is not ready for writes until service/characteristic
        // discovery has completed. Keep connect() suspended until then, with a
        // bounded fallback for peripherals that expose no discoverable metadata.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard let self, self.connectionWaiters[peripheral.identifier] != nil else { return }
            if self.characteristics[peripheral.identifier] != nil { self.finishConnection(peripheral.identifier) }
            else { self.finishConnection(peripheral.identifier, error: BLETransportError.characteristicNotFound) }
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let waiters = connectionWaiters.removeValue(forKey: peripheral.identifier) ?? []
        waiters.forEach { $0.resume(throwing: error ?? BLETransportError.disconnected) }
        emit(.disconnected(peripheral.identifier, error?.localizedDescription))
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        characteristics.removeValue(forKey: peripheral.identifier)
        finishConnection(peripheral.identifier, error: error ?? BLETransportError.disconnected)
        emit(.disconnected(peripheral.identifier, error?.localizedDescription))
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            finishConnection(peripheral.identifier, error: error!)
            emit(.diagnostic(.init(deviceID: peripheral.identifier, kind: "gatt", detail: error!.localizedDescription)))
            return
        }
        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
                characteristics[peripheral.identifier] = characteristic
                finishConnection(peripheral.identifier)
            }
            if characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let data = characteristic.value { emit(.notification(peripheral.identifier, data)) }
        if let error { emit(.diagnostic(.init(deviceID: peripheral.identifier, kind: "notify", detail: error.localizedDescription))) }
    }
}
#else
/// Host-test fallback. iOS builds always take the CoreBluetooth implementation
/// above; this keeps pure frame/queue/store tests runnable on a non-Apple host.
@MainActor
public final class BLETransport: @unchecked Sendable {
    public let restorationIdentifier: String
    public private(set) var state: LEDTransportState = .idle
    public private(set) var advertisements: [UUID: BLEAdvertisement] = [:]
    public init(restorationIdentifier: String = "fun.fuckmmw.ledunion.ble") { self.restorationIdentifier = restorationIdentifier }
    public func events() -> AsyncStream<BLEEvent> { AsyncStream { $0.finish() } }
    public func startScan() { state = .failed }
    public func stopScan() { state = .idle }
    public func connect(id: UUID) async throws { throw BLETransportError.unavailable }
    public func disconnect(id: UUID) {}
    public func write(id: UUID, data: Data, characteristicUUID: String, withoutResponse: Bool) throws { throw BLETransportError.unavailable }
}
#endif
