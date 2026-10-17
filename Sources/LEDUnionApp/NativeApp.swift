#if os(iOS)
import Combine
import Foundation
import SwiftUI
import LEDUnionCore
import LEDUnionIntents

@MainActor
public final class NativeAppModel: ObservableObject {
    public let store: LEDStore
    public let manager: DeviceManager

    @Published public private(set) var devices: [LEDDevice] = []
    @Published public private(set) var discovered: [BLEAdvertisement] = []
    @Published public private(set) var diagnostics: [LEDDiagnosticEvent] = []
    @Published public private(set) var transportState: LEDTransportState = .idle
    @Published public var selectedDeviceID: UUID?
    @Published public var red = 255
    @Published public var green = 0
    @Published public var blue = 0
    @Published public var brightness = 100
    @Published public var power = true
    @Published public private(set) var scanning = false
    @Published public var error: String?

    private var eventTask: Task<Void, Never>?

    public init() {
        store = (try? LEDStore.applicationSupport())
            ?? LEDStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("led-union.json"))
        manager = DeviceManager(store: store)
        eventTask = Task { [weak self] in
            guard let self else { return }
            for await event in manager.transport.events() {
                handle(event)
            }
        }
        Task { [weak self] in await self?.bootstrap() }
    }

    public func bootstrap() async {
        try? await store.load()
        await refresh()
    }

    public func refresh() async {
        let state = await store.snapshot()
        devices = state.devices
        if selectedDeviceID == nil { selectedDeviceID = state.devices.first?.id }
        if let id = selectedDeviceID, let device = state.devices.first(where: { $0.id == id }) {
            red = Int(device.lastLook.color?.red ?? 255)
            green = Int(device.lastLook.color?.green ?? 0)
            blue = Int(device.lastLook.color?.blue ?? 0)
            brightness = device.lastLook.brightness ?? 100
            power = device.lastLook.power ?? true
        }
        diagnostics = await manager.diagnostics.history()
    }

    public func scan() async {
        error = nil
        discovered = []
        scanning = true
        manager.transport.startScan()
        try? await Task.sleep(for: .seconds(8))
        manager.transport.stopScan()
        transportState = manager.transport.state
        discovered = manager.transport.advertisements.values
            .filter { DriverRegistry.supports(advertisedName: $0.name) }
            .sorted { $0.rssi > $1.rssi }
        scanning = false
        if discovered.isEmpty {
            error = "Совместимый LED-контроллер не найден. Проверьте Bluetooth и имя контроллера."
        }
    }

    public func connect(_ advertisement: BLEAdvertisement) async {
        error = nil
        selectedDeviceID = advertisement.id
        do {
            try await manager.connect(id: advertisement.id, advertisedName: advertisement.name)
            await refresh()
            LEDAppShortcuts.updateAppShortcutParameters()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func connect(_ device: LEDDevice) async {
        error = nil
        selectedDeviceID = device.id
        do {
            try await manager.connect(id: device.id, advertisedName: device.advertisedName)
            await refresh()
            LEDAppShortcuts.updateAppShortcutParameters()
        } catch {
            self.error = error.localizedDescription
        }
    }

    public func disconnect(_ device: LEDDevice) async {
        await manager.disconnect(id: device.id)
        await refresh()
    }

    public func applyColor() async {
        await send(.color(RGBColor(red: red, green: green, blue: blue)), key: "color")
    }

    public func applyBrightness() async {
        await send(.brightness(brightness), key: "brightness")
    }

    public func setPower(_ value: Bool) async {
        power = value
        await send(.power(value), key: nil)
    }

    public func applyEffect(id: Int, name: String) async {
        await send(.effect(LEDEffect(id: id, name: name)), key: "effect")
    }

    private func send(_ command: LEDCommand, key: String?) async {
        guard let id = selectedDeviceID else {
            error = "Сначала выберите и подключите устройство."
            return
        }
        do {
            try await manager.send(command, to: id, coalescingKey: key)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func handle(_ event: BLEEvent) {
        switch event {
        case .state(let state): transportState = state
        case .discovered(let advertisement):
            if !discovered.contains(where: { $0.id == advertisement.id }) { discovered.append(advertisement) }
        case .diagnostic:
            Task { await refresh() }
        case .connected, .disconnected, .notification:
            Task { await refresh() }
        }
    }
}

@MainActor
public struct NativeRootView: View {
    @StateObject private var model: NativeAppModel

    public init(model: NativeAppModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        TabView {
            NativeDevicesView(model: model)
                .tabItem { Label("Устройства", systemImage: "lightbulb.2") }
            NativeEffectsView(model: model)
                .tabItem { Label("Эффекты", systemImage: "sparkles") }
            NativeDiagnosticsView(model: model)
                .tabItem { Label("Диагностика", systemImage: "stethoscope") }
        }
        .tint(.accentColor)
    }
}

@MainActor
private struct NativeDevicesView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await model.scan() }
                    } label: {
                        Label(model.scanning ? "Сканирование…" : "Добавить устройство", systemImage: "plus.circle.fill")
                    }
                    .disabled(model.scanning)
                    if model.scanning { ProgressView("Ищем BLE-контроллеры…") }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                    }
                }

                if !model.discovered.isEmpty {
                    Section("Найдено") {
                        ForEach(model.discovered) { advertisement in
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(advertisement.name)
                                    Text("RSSI \(advertisement.rssi) · \(advertisement.serviceUUIDs.joined(separator: ", "))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Подключить") { Task { await model.connect(advertisement) } }
                            }
                        }
                    }
                }

                Section("Сохранённые устройства") {
                    if model.devices.isEmpty {
                        Text("Устройств пока нет")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.devices) { device in
                            NativeDeviceRow(model: model, device: device)
                        }
                    }
                }

                if model.selectedDeviceID != nil {
                    NativeControls(model: model)
                }
            }
            .navigationTitle("LED Union")
            .refreshable { await model.refresh() }
        }
    }
}

@MainActor
private struct NativeDeviceRow: View {
    @ObservedObject var model: NativeAppModel
    let device: LEDDevice

    var body: some View {
        HStack {
            Circle().fill(device.connected ? .green : .gray).frame(width: 10, height: 10)
            VStack(alignment: .leading) {
                Text(device.label ?? device.advertisedName)
                Text(device.driverID).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if device.connected {
                Button("Отключить") { Task { await model.disconnect(device) } }
            } else {
                Button("Подключить") { Task { await model.connect(device) } }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.selectedDeviceID = device.id }
    }
}

@MainActor
private struct NativeControls: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        Section("Управление") {
            Toggle("Питание", isOn: Binding(
                get: { model.power },
                set: { value in Task { await model.setPower(value) } }
            ))
            VStack(alignment: .leading) {
                HStack { Text("Цвет"); Spacer(); RoundedRectangle(cornerRadius: 8).fill(Color(red: Double(model.red) / 255, green: Double(model.green) / 255, blue: Double(model.blue) / 255)).frame(width: 40, height: 24) }
                NativeRGBSlider(label: "R", value: $model.red, color: .red)
                NativeRGBSlider(label: "G", value: $model.green, color: .green)
                NativeRGBSlider(label: "B", value: $model.blue, color: .blue)
                Button("Применить цвет") { Task { await model.applyColor() } }
            }
            VStack(alignment: .leading) {
                Text("Яркость: \(model.brightness)%")
                Slider(value: Binding(get: { Double(model.brightness) }, set: { model.brightness = Int($0.rounded()) }), in: 0...100, step: 1)
                Button("Применить яркость") { Task { await model.applyBrightness() } }
            }
        }
    }
}

@MainActor
private struct NativeRGBSlider: View {
    let label: String
    @Binding var value: Int
    let color: Color

    var body: some View {
        HStack {
            Text(label).foregroundStyle(color).frame(width: 20)
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }), in: 0...255, step: 1)
            Text("\(value)").monospacedDigit().frame(width: 36, alignment: .trailing)
        }
    }
}

@MainActor
private struct NativeEffectsView: View {
    @ObservedObject var model: NativeAppModel
    private let effects = [(1, "Плавный переход"), (2, "Смена цвета"), (3, "Радуга"), (4, "Дыхание"), (5, "Пульс"), (6, "Стробоскоп")]

    var body: some View {
        NavigationStack {
            List(effects, id: \.0) { effect in
                Button(effect.1) { Task { await model.applyEffect(id: effect.0, name: effect.1) } }
            }
            .navigationTitle("Эффекты")
        }
    }
}

@MainActor
private struct NativeDiagnosticsView: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Bluetooth") {
                    LabeledContent("Состояние", value: model.transportState.rawValue)
                    LabeledContent("Найдено", value: String(model.discovered.count))
                }
                Section("Журнал") {
                    if model.diagnostics.isEmpty { Text("Пока пусто").foregroundStyle(.secondary) }
                    ForEach(Array(model.diagnostics.enumerated()), id: \.offset) { _, event in
                        VStack(alignment: .leading) {
                            Text(event.kind).font(.headline)
                            Text(event.detail).font(.caption)
                            Text(event.timestamp.formatted()).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Диагностика")
        }
    }
}
#endif
