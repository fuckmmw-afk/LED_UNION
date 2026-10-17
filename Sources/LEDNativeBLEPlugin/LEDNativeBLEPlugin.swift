import Capacitor
import Foundation
import LEDUnionCore

@objc(LEDNativeBLEPlugin)
@MainActor
public final class LEDNativeBLEPlugin: CAPPlugin, CAPBridgedPlugin {
    public let identifier = "LEDNativeBLEPlugin"
    public let jsName = "LEDNativeBLE"
    public let pluginMethods: [CAPPluginMethod] = [
        CAPPluginMethod(name: "scan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "stopScan", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "connect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "disconnect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setColor", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setBrightness", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setPower", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "setEffect", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "sendRaw", returnType: CAPPluginReturnPromise),
        CAPPluginMethod(name: "diagnostics", returnType: CAPPluginReturnPromise),
    ]

    private var manager: DeviceManager?
    private var streamTask: Task<Void, Never>?

    override public func load() {
        let store = (try? LEDStore.applicationSupport()) ?? LEDStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("led-union.json"))
        manager = DeviceManager(store: store)
        Task { try? await store.load() }
        streamTask = Task { [weak self] in
            guard let self, let manager = self.manager else { return }
            for await event in manager.transport.events() { self.emit(event) }
        }
    }

    @objc func scan(_ call: CAPPluginCall) {
        guard let manager else { call.reject("BLE manager is unavailable"); return }
        manager.transport.startScan()
        let timeout = UInt64(max(250, min(15_000, call.getInt("timeoutMs") ?? 5_000))) * 1_000_000
        Task { @MainActor [weak self, weak manager] in
            try? await Task.sleep(nanoseconds: timeout)
            manager?.transport.stopScan()
            let devices: [[String: Any]] = manager?.transport.advertisements.values
                .filter { DriverRegistry.supports(advertisedName: $0.name) }
                .map { self?.encode($0) ?? [String: Any]() } ?? []
            call.resolve(["devices": devices])
        }
    }

    @objc func stopScan(_ call: CAPPluginCall) { manager?.transport.stopScan(); call.resolve() }

    @objc func connect(_ call: CAPPluginCall) {
        guard let manager, let id = UUID(uuidString: call.getString("deviceId") ?? ""), let name = call.getString("name") else {
            call.reject("deviceId and name are required"); return
        }
        Task {
            do { try await manager.connect(id: id, advertisedName: name); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func disconnect(_ call: CAPPluginCall) {
        guard let manager, let id = UUID(uuidString: call.getString("deviceId") ?? "") else { call.reject("deviceId is required"); return }
        Task { await manager.disconnect(id: id); call.resolve() }
    }

    @objc func setColor(_ call: CAPPluginCall) { runCommand(call) { .color(try self.color(call)) } }
    @objc func setBrightness(_ call: CAPPluginCall) { runCommand(call) { .brightness(call.getInt("brightness") ?? 0) } }
    @objc func setPower(_ call: CAPPluginCall) { runCommand(call) { .power(call.getBool("on") ?? false) } }
    @objc func setEffect(_ call: CAPPluginCall) { runCommand(call) { .effect(.init(id: call.getInt("effectId") ?? 0, name: call.getString("name") ?? "Effect")) } }

    @objc func sendRaw(_ call: CAPPluginCall) {
        guard let manager, let id = UUID(uuidString: call.getString("deviceId") ?? ""),
              let value = call.getString("hex") else { call.reject("deviceId and hex are required"); return }
        let bytes = value.split(whereSeparator: { $0 == " " || $0 == ":" }).compactMap { UInt8($0, radix: 16) }
        guard !bytes.isEmpty else { call.reject("hex is invalid"); return }
        Task {
            do {
                try await manager.sendRaw(Data(bytes), to: id, coalescingKey: call.getString("coalescingKey"))
                call.resolve()
            } catch { call.reject(error.localizedDescription) }
        }
    }

    @objc func diagnostics(_ call: CAPPluginCall) {
        guard let id = UUID(uuidString: call.getString("deviceId") ?? "") else { call.reject("deviceId is required"); return }
        let services = manager?.transport.advertisements[id]?.serviceUUIDs.map { ["uuid": $0, "characteristics": [String]()] } ?? []
        Task {
            let history = await manager?.diagnostics.history().map { ["timestamp": $0.timestamp.ISO8601Format(), "kind": $0.kind, "detail": $0.detail] } ?? []
            call.resolve(["services": services, "history": history])
        }
    }

    private func runCommand(_ call: CAPPluginCall, make: @escaping () throws -> LEDCommand) {
        guard let manager, let id = UUID(uuidString: call.getString("deviceId") ?? "") else { call.reject("deviceId is required"); return }
        Task {
            do { try await manager.send(make(), to: id, coalescingKey: call.getString("coalescingKey")); call.resolve() }
            catch { call.reject(error.localizedDescription) }
        }
    }

    private func color(_ call: CAPPluginCall) throws -> RGBColor {
        guard let value = call.getString("hex"), let color = RGBColor(hex: value) else { throw NSError(domain: "LEDNativeBLE", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid HEX color"]) }
        return color
    }

    private func encode(_ value: BLEAdvertisement) -> [String: Any] {
        ["id": value.id.uuidString, "name": value.name, "rssi": value.rssi, "serviceUUIDs": value.serviceUUIDs]
    }

    private func emit(_ event: BLEEvent) {
        switch event {
        case .discovered(let value): notifyListeners("bleEvent", data: ["type": "discovered", "deviceId": value.id.uuidString, "name": value.name, "rssi": value.rssi])
        case .connected(let id): notifyListeners("bleEvent", data: ["type": "connected", "deviceId": id.uuidString])
        case .disconnected(let id, let error): notifyListeners("bleEvent", data: ["type": "disconnected", "deviceId": id.uuidString, "message": error as Any])
        case .state(let state): notifyListeners("bleEvent", data: ["type": "state", "message": state.rawValue])
        case .diagnostic(let event): notifyListeners("bleEvent", data: ["type": "diagnostic", "deviceId": event.deviceID?.uuidString as Any, "message": event.detail])
        case .notification: break
        }
    }
}
