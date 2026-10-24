#if os(iOS)
import Combine
import Foundation
import SwiftUI
import UIKit
import LEDUnionCore
import LEDUnionIntents

// MARK: - Model

public enum LightTarget: Hashable, Sendable {
    case all
    case device(UUID)
}

public struct EffectGroup: Identifiable, Sendable {
    public let group: String
    public let effects: [LEDEffect]
    public var id: String { group }
}

public struct AppToast: Identifiable, Equatable {
    public enum Style: Equatable { case info, success, error }
    public let id = UUID()
    public let text: String
    public let style: Style
}

@MainActor
public final class NativeAppModel: ObservableObject {
    public let runtime: LEDRuntime
    public var manager: DeviceManager { runtime.manager }

    @Published public private(set) var devices: [LEDDevice] = []
    @Published public private(set) var phases: [UUID: LEDConnectionPhase] = [:]
    @Published public private(set) var found: [BLEAdvertisement] = []
    @Published public private(set) var otherDevicesSeen = 0
    @Published public private(set) var scanning = false
    @Published public private(set) var bluetooth: BluetoothPowerState = .unknown
    @Published public private(set) var diagnostics: [LEDDiagnosticEvent] = []
    @Published public private(set) var scenes: [LEDScene] = []
    @Published public private(set) var history: [RGBColor] = []
    @Published public var toast: AppToast?

    @Published public var target: LightTarget = .all
    @Published public var color = RGBColor(red: 255, green: 255, blue: 255)
    @Published public var brightness: Double = 100
    @Published public var speed: Double = 50
    @Published public var white: Double = 100
    @Published public var warmth: Double = 50
    @Published public var power = true
    @Published public private(set) var softwareEffect: SoftwareEffect?
    @Published public private(set) var micActive = false
    @Published public var micSensitivity: Double = 1

    private var eventTask: Task<Void, Never>?
    private var scanStopTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    private var seenNames: [UUID: String] = [:]
    private var livePending: [String: LEDCommand] = [:]
    private var liveInFlight: Set<String> = []
    private let effectController = EffectTaskController()
    private let effectToken = UUID()
    private let audio = AudioReactiveEngine()
    private var micHue: Double = 0
    private var lastShortcutRefresh = Date.distantPast

    public init(runtime: LEDRuntime = .shared) {
        self.runtime = runtime
        let stream = runtime.manager.events()
        eventTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        Task { [weak self] in
            await runtime.start()
            await self?.reload()
            self?.restoreControls()
        }
    }

    // MARK: Derived state

    public var targetIDs: [UUID] {
        switch target {
        case .all: return devices.map(\.id)
        case .device(let id): return devices.contains { $0.id == id } ? [id] : []
        }
    }

    public var targetDevices: [LEDDevice] { devices.filter { targetIDs.contains($0.id) } }

    public var targetName: String {
        switch target {
        case .all: return devices.count == 1 ? devices[0].displayName : "Все устройства"
        case .device(let id): return devices.first { $0.id == id }?.displayName ?? "Устройство"
        }
    }

    /// Capabilities shared by every targeted device.
    public var targetCapabilities: LEDCapabilities {
        let caps = targetDevices.map { manager.driver(for: $0).capabilities }
        guard !caps.isEmpty else { return LEDCapabilities() }
        return LEDCapabilities(rgb: caps.contains { $0.rgb },
                               white: caps.contains { $0.white },
                               cct: caps.contains { $0.cct },
                               speed: caps.contains { $0.speed },
                               effects: caps.contains { $0.effects },
                               scenes: caps.contains { $0.scenes })
    }

    /// Built-in effects of the first targeted device, grouped as in the original app.
    public var targetEffects: [EffectGroup] {
        guard let device = targetDevices.first else { return [] }
        let effects = manager.driver(for: device).effects
        var order: [String] = []
        var groups: [String: [LEDEffect]] = [:]
        for effect in effects {
            let group = Self.groupTitle(effect.group)
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(effect)
        }
        return order.map { EffectGroup(group: $0, effects: groups[$0] ?? []) }
    }

    public var targetHasMixedFamilies: Bool {
        Set(targetDevices.map { DriverRegistry.familyName(for: $0.advertisedName) }).count > 1
    }

    public var currentEffect: LEDEffect? { targetDevices.first?.lastLook.effect }

    public func phase(_ id: UUID) -> LEDConnectionPhase { phases[id] ?? .idle }

    public var connectedCount: Int { devices.filter { phase($0.id).isReady }.count }

    private static func groupTitle(_ group: String?) -> String {
        switch group {
        case nil: return "Эффекты"
        case "Basic": return "Основные"
        case "Curtain": return "Шторка"
        case "Trans": return "Переходы"
        case "Scenes": return "Сцены контроллера"
        case let other?: return other
        }
    }

    // MARK: Loading

    public func reload() async {
        let state = await runtime.store.snapshot()
        devices = state.devices
        scenes = state.scenes
        history = state.history
        for device in state.devices { phases[device.id] = manager.phase(for: device.id) }
        if case .device(let id) = target, !state.devices.contains(where: { $0.id == id }) { target = .all }
        diagnostics = await manager.diagnostics.history()
        refreshShortcutsIfNeeded()
    }

    private func restoreControls() {
        guard let look = targetDevices.first?.lastLook else { return }
        if let value = look.color { color = value }
        if let value = look.brightness { brightness = Double(value) }
        if let value = look.speed { speed = Double(value) }
        if let value = look.white { white = Double(value) }
        if let value = look.warmth { warmth = Double(value) }
        power = look.power ?? true
    }

    public func selectTarget(_ next: LightTarget) {
        target = next
        restoreControls()
    }

    private func refreshShortcutsIfNeeded() {
        guard Date().timeIntervalSince(lastShortcutRefresh) > 2 else { return }
        lastShortcutRefresh = Date()
        LEDAppShortcuts.updateAppShortcutParameters()
    }

    private func handle(_ event: DeviceManagerEvent) async {
        switch event {
        case .phase(let id, let phase):
            let previous = phases[id]
            phases[id] = phase
            if phase == .ready, previous != .ready, let device = devices.first(where: { $0.id == id }) {
                show("Подключено: \(device.displayName)", .success)
            }
        case .devicesChanged:
            await reload()
        case .bluetooth(let state):
            bluetooth = state
        case .scanning(let value):
            scanning = value
        case .discovered(let advertisement):
            guard scanning else { return }
            if DriverRegistry.supports(advertisedName: advertisement.name) {
                if let index = found.firstIndex(where: { $0.id == advertisement.id }) { found[index] = advertisement }
                else { found.append(advertisement) }
                found.sort { $0.rssi > $1.rssi }
            } else {
                seenNames[advertisement.id] = advertisement.name
                otherDevicesSeen = seenNames.count
            }
        case .diagnostic(let event):
            diagnostics.append(event)
            if diagnostics.count > 500 { diagnostics.removeFirst(diagnostics.count - 500) }
        }
    }

    // MARK: Toasts

    public func show(_ text: String, _ style: AppToast.Style = .info) {
        let next = AppToast(text: text, style: style)
        toast = next
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(style == .error ? 5 : 2.5))
            guard !Task.isCancelled, self?.toast == next else { return }
            self?.toast = nil
        }
    }

    private func report(_ failures: [UUID: String]) {
        guard let first = failures.first else { return }
        let name = devices.first { $0.id == first.key }?.displayName ?? "Устройство"
        show(failures.count > 1 ? "\(failures.count) устройств не ответили: \(first.value)" : "\(name): \(first.value)", .error)
    }

    // MARK: Scanning and connections

    public func toggleScan() {
        scanning ? stopScan() : startScan()
    }

    public func startScan() {
        found = []
        seenNames = [:]
        otherDevicesSeen = 0
        manager.transport.startScan()
        scanning = true
        scanStopTask?.cancel()
        scanStopTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.stopScan()
        }
    }

    public func stopScan() {
        scanStopTask?.cancel()
        manager.transport.stopScan()
        scanning = false
    }

    public func connect(_ advertisement: BLEAdvertisement) async {
        // Scanning while connecting makes cheap controllers drop the first attempt.
        stopScan()
        found.removeAll { $0.id == advertisement.id }
        phases[advertisement.id] = .connecting(attempt: 1)
        do {
            try await manager.connect(id: advertisement.id, advertisedName: advertisement.name)
            await reload()
            if devices.count == 1 { target = .device(advertisement.id) }
        } catch is CancellationError {
        } catch {
            await reload()
            if !devices.contains(where: { $0.id == advertisement.id }) { found.append(advertisement) }
            show("\(advertisement.name): \(error.localizedDescription)", .error)
        }
    }

    public func connect(_ device: LEDDevice) async {
        do {
            try await manager.connect(id: device.id, advertisedName: device.advertisedName)
        } catch is CancellationError {
        } catch {
            show("\(device.displayName): \(error.localizedDescription)", .error)
        }
        await reload()
    }

    public func disconnect(_ device: LEDDevice) async {
        await manager.disconnect(id: device.id)
        await reload()
    }

    public func forget(_ device: LEDDevice) async {
        await manager.forget(id: device.id)
        await reload()
        show("Удалено: \(device.displayName)")
    }

    public func rename(_ device: LEDDevice, to label: String) async {
        await manager.rename(id: device.id, to: label)
        await reload()
    }

    public func setAutoConnect(_ device: LEDDevice, _ enabled: Bool) async {
        await manager.setAutoConnect(id: device.id, enabled)
        await reload()
    }

    public func connectAll() async {
        for device in devices where !phase(device.id).isReady && !phase(device.id).isBusy {
            Task { await connect(device) }
        }
    }

    public func resume() { manager.resume() }

    // MARK: Commands

    /// Sends a command to the target and persists the result.
    public func commit(_ command: LEDCommand) async {
        let ids = targetIDs
        guard !ids.isEmpty else {
            show("Сначала добавьте устройство на вкладке «Устройства»", .error)
            return
        }
        let failures = await manager.apply(command, to: ids)
        report(failures)
        await reload()
    }

    /// Latest-value-wins sending for sliders and the colour wheel: at most one frame
    /// per key is in flight, and intermediate values are dropped instead of queued.
    public func live(_ command: LEDCommand, key: String) {
        livePending[key] = command
        guard !liveInFlight.contains(key) else { return }
        liveInFlight.insert(key)
        Task { [weak self] in
            guard let self else { return }
            var failures: [UUID: String] = [:]
            while let next = self.livePending.removeValue(forKey: key) {
                failures = await self.manager.apply(next, to: self.targetIDs, coalescingKey: key, remember: false)
                if !failures.isEmpty { self.livePending.removeValue(forKey: key) }
            }
            self.liveInFlight.remove(key)
            self.report(failures)
        }
    }

    public func setPower(_ value: Bool) async {
        power = value
        await stopSoftwareModes()
        await commit(.power(value))
    }

    public func pick(_ value: RGBColor) async {
        color = value
        power = true
        await stopSoftwareModes()
        await commit(.color(value))
    }

    public func liveColor(_ value: RGBColor) {
        color = value
        if softwareEffect != nil || micActive { Task { await stopSoftwareModes() } }
        live(.color(value), key: "color")
    }

    public func finishColorDrag() async { await commit(.color(color)) }

    public func liveBrightness() { live(.brightness(Int(brightness.rounded())), key: "brightness") }
    public func finishBrightness() async { await commit(.brightness(Int(brightness.rounded()))) }
    public func liveSpeed() { live(.speed(Int(speed.rounded())), key: "speed") }
    public func finishSpeed() async { await commit(.speed(Int(speed.rounded()))) }
    public func liveWhite() { live(.white(Int(white.rounded())), key: "white") }
    public func finishWhite() async { await commit(.white(Int(white.rounded()))) }
    public func liveWarmth() { live(.warmth(Int(warmth.rounded())), key: "warmth") }
    public func finishWarmth() async { await commit(.warmth(Int(warmth.rounded()))) }

    public func applyEffect(_ effect: LEDEffect) async {
        await stopSoftwareModes()
        power = true
        await commit(.effect(effect))
    }

    // MARK: Software effects and microphone

    public func toggleSoftwareEffect(_ effect: SoftwareEffect) async {
        if softwareEffect == effect {
            await stopSoftwareModes()
            return
        }
        await stopSoftwareModes()
        guard !targetIDs.isEmpty else {
            show("Сначала добавьте устройство", .error)
            return
        }
        softwareEffect = effect
        let interval = Duration.milliseconds(Int(220 - speed * 1.9))
        let model = self
        _ = await effectController.start(deviceID: effectToken, effect: effect, interval: interval) { frame in
            await model.live(.color(frame), key: "software-effect")
        }
    }

    public func toggleMicrophone() async {
        if micActive {
            await stopSoftwareModes()
            return
        }
        await stopSoftwareModes()
        guard !targetIDs.isEmpty else {
            show("Сначала добавьте устройство", .error)
            return
        }
        audio.onLevel = { [weak self] rms, bass, beat in
            self?.micLevel(rms: rms, bass: bass, beat: beat)
        }
        do {
            try await audio.start()
            micActive = true
        } catch {
            show(error.localizedDescription, .error)
        }
    }

    private func micLevel(rms: Double, bass: Double, beat: Double) {
        guard micActive else { return }
        let level = min(1, rms * micSensitivity)
        micHue = (micHue + 0.004 + bass * 0.03 + beat * 0.08).truncatingRemainder(dividingBy: 1)
        let value = 0.08 + 0.92 * level
        live(.color(Self.hsv(hue: micHue, saturation: 1, value: value)), key: "microphone")
    }

    public func stopSoftwareModes() async {
        if softwareEffect != nil {
            softwareEffect = nil
            await effectController.cancel(deviceID: effectToken)
        }
        if micActive {
            micActive = false
            audio.stop()
            audio.onLevel = nil
        }
        livePending.removeValue(forKey: "software-effect")
        livePending.removeValue(forKey: "microphone")
    }

    static func hsv(hue: Double, saturation: Double, value: Double) -> RGBColor {
        let h = (hue - floor(hue)) * 6
        let i = Int(h)
        let f = h - Double(i)
        let p = value * (1 - saturation), q = value * (1 - saturation * f), t = value * (1 - saturation * (1 - f))
        let rgb: (Double, Double, Double)
        switch i % 6 {
        case 0: rgb = (value, t, p)
        case 1: rgb = (q, value, p)
        case 2: rgb = (p, value, t)
        case 3: rgb = (p, q, value)
        case 4: rgb = (t, p, value)
        default: rgb = (value, p, q)
        }
        return RGBColor(red: Int(rgb.0 * 255), green: Int(rgb.1 * 255), blue: Int(rgb.2 * 255))
    }

    // MARK: Scenes

    public func saveScene(named name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !devices.isEmpty else {
            show("Нет устройств для сцены", .error)
            return
        }
        do {
            try await manager.scenes.save(name: trimmed, deviceIDs: targetIDs.isEmpty ? devices.map(\.id) : targetIDs)
            await reload()
            LEDAppShortcuts.updateAppShortcutParameters()
            show("Сцена «\(trimmed)» сохранена", .success)
        } catch {
            show(error.localizedDescription, .error)
        }
    }

    public func applyScene(_ scene: LEDScene) async {
        await stopSoftwareModes()
        do {
            let failures = try await manager.applyScene(scene.id)
            if failures.isEmpty { show("Сцена «\(scene.name)» применена", .success) } else { report(failures) }
        } catch {
            show(error.localizedDescription, .error)
        }
        await reload()
        restoreControls()
    }

    public func deleteScene(_ scene: LEDScene) async {
        try? await manager.scenes.delete(scene.id)
        await reload()
        LEDAppShortcuts.updateAppShortcutParameters()
    }

    // MARK: Diagnostics

    public func clearDiagnostics() async {
        await manager.diagnostics.clear()
        diagnostics = []
    }

    public var diagnosticsText: String {
        let formatter = ISO8601DateFormatter()
        let header = devices.map { "\($0.displayName) [\($0.advertisedName)] \($0.id.uuidString) — \(phase($0.id).title)" }
        let lines = diagnostics.map { event in
            let device = event.deviceID.flatMap { id in devices.first { $0.id == id }?.displayName } ?? "-"
            return "\(formatter.string(from: event.timestamp)) \(device) \(event.kind): \(event.detail)"
        }
        return (["Bluetooth: \(bluetooth.rawValue)"] + header + [""] + lines).joined(separator: "\n")
    }
}

// MARK: - Presentation helpers

public extension LEDConnectionPhase {
    var title: String {
        switch self {
        case .idle: return "Не подключено"
        case .waitingForBluetooth: return "Ожидание Bluetooth…"
        case .connecting(let attempt): return attempt > 1 ? "Подключение… попытка \(attempt) из 3" : "Подключение…"
        case .discovering: return "Поиск сервисов…"
        case .linked: return "Сервисы найдены…"
        case .handshaking: return "Авторизация…"
        case .ready: return "Подключено"
        case .reconnecting(let attempt): return attempt == 0 ? "Связь потеряна, переподключаемся…" : "Переподключение, попытка \(attempt)…"
        case .failed(let message): return "Ошибка: \(message)"
        }
    }

    /// 0...1 progress through the connection steps, for the per-row progress bar.
    var progress: Double? {
        switch self {
        case .waitingForBluetooth: return 0.1
        case .connecting, .reconnecting: return 0.3
        case .discovering: return 0.55
        case .linked: return 0.7
        case .handshaking: return 0.85
        default: return nil
        }
    }

    var tint: Color {
        switch self {
        case .ready: return .green
        case .failed: return .red
        case .idle: return .gray
        default: return .orange
        }
    }
}

extension RGBColor {
    var swiftUIColor: Color { Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255) }

    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(red: Int((r * 255).rounded()), green: Int((g * 255).rounded()), blue: Int((b * 255).rounded()))
    }

    var hue: Double {
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        UIColor(swiftUIColor).getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        return Double(h)
    }
}

private let presetColors: [(String, RGBColor)] = [
    ("Красный", RGBColor(red: 255, green: 0, blue: 0)),
    ("Оранжевый", RGBColor(red: 255, green: 100, blue: 0)),
    ("Жёлтый", RGBColor(red: 255, green: 210, blue: 0)),
    ("Лайм", RGBColor(red: 140, green: 255, blue: 0)),
    ("Зелёный", RGBColor(red: 0, green: 255, blue: 0)),
    ("Бирюзовый", RGBColor(red: 0, green: 255, blue: 160)),
    ("Голубой", RGBColor(red: 0, green: 220, blue: 255)),
    ("Синий", RGBColor(red: 0, green: 0, blue: 255)),
    ("Фиолетовый", RGBColor(red: 150, green: 0, blue: 255)),
    ("Розовый", RGBColor(red: 255, green: 40, blue: 150)),
    ("Тёплый", RGBColor(red: 255, green: 170, blue: 80)),
    ("Белый", RGBColor(red: 255, green: 255, blue: 255)),
]

private extension SoftwareEffect {
    var title: String {
        switch self {
        case .smoothFade: return "Плавный переход"
        case .colorCycle: return "Смена цветов"
        case .rainbow: return "Радуга"
        case .breathing: return "Дыхание"
        case .pulse: return "Пульс"
        case .strobe: return "Стробоскоп"
        case .candle: return "Свеча"
        case .sunset: return "Закат"
        case .ambient: return "Спокойный"
        case .randomColors: return "Случайные цвета"
        case .customGradient: return "Градиент"
        }
    }

    var icon: String {
        switch self {
        case .smoothFade, .customGradient: return "wand.and.rays"
        case .colorCycle, .rainbow: return "rainbow"
        case .breathing: return "lungs.fill"
        case .pulse: return "waveform.path.ecg"
        case .strobe: return "bolt.fill"
        case .candle: return "flame.fill"
        case .sunset: return "sunset.fill"
        case .ambient: return "moon.stars.fill"
        case .randomColors: return "dice.fill"
        }
    }
}

// MARK: - Root

@MainActor
public struct NativeRootView: View {
    @StateObject private var model: NativeAppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = 0

    public init(model: NativeAppModel) {
        _model = StateObject(wrappedValue: model)
    }

    public var body: some View {
        TabView(selection: $tab) {
            DevicesScreen(model: model, openLight: { tab = 1 })
                .tabItem { Label("Устройства", systemImage: "lightbulb.2") }
                .badge(model.devices.isEmpty ? 0 : model.connectedCount)
                .tag(0)
            LightScreen(model: model)
                .tabItem { Label("Свет", systemImage: "paintpalette") }
                .tag(1)
            EffectsScreen(model: model)
                .tabItem { Label("Эффекты", systemImage: "sparkles") }
                .tag(2)
            ScenesScreen(model: model)
                .tabItem { Label("Сцены", systemImage: "theatermasks") }
                .tag(3)
            DiagnosticsScreen(model: model)
                .tabItem { Label("Журнал", systemImage: "list.bullet.rectangle") }
                .tag(4)
        }
        .overlay(alignment: .top) { ToastView(toast: model.toast).animation(.spring(duration: 0.35), value: model.toast) }
        .sensoryFeedback(trigger: model.toast) { _, toast in
            switch toast?.style {
            case .success: return .success
            case .error: return .error
            default: return nil
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.resume() }
        }
    }
}

private struct ToastView: View {
    let toast: AppToast?

    var body: some View {
        if let toast {
            HStack(spacing: 10) {
                Image(systemName: icon(toast.style)).foregroundStyle(color(toast.style))
                Text(toast.text).font(.subheadline.weight(.medium)).multilineTextAlignment(.leading)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .transition(.move(edge: .top).combined(with: .opacity))
            .id(toast.id)
        }
    }

    private func icon(_ style: AppToast.Style) -> String {
        switch style {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private func color(_ style: AppToast.Style) -> Color {
        switch style {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        }
    }
}

// MARK: - Devices

private struct BluetoothBanner: View {
    let state: BluetoothPowerState
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch state {
        case .poweredOff:
            Label("Bluetooth выключен. Включите его в Пункте управления — подключение продолжится само.", systemImage: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.orange)
        case .unauthorized:
            VStack(alignment: .leading, spacing: 8) {
                Label("Нет доступа к Bluetooth", systemImage: "lock.fill").foregroundStyle(.red)
                Button("Открыть настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            }
        case .unsupported:
            Label("Bluetooth LE не поддерживается", systemImage: "xmark.octagon").foregroundStyle(.red)
        case .resetting:
            Label("Bluetooth перезапускается…", systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
        case .unknown, .poweredOn:
            EmptyView()
        }
    }
}

@MainActor
private struct DevicesScreen: View {
    @ObservedObject var model: NativeAppModel
    let openLight: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if model.bluetooth != .poweredOn && model.bluetooth != .unknown {
                    Section { BluetoothBanner(state: model.bluetooth) }
                }

                Section {
                    if model.devices.isEmpty {
                        ContentUnavailableView("Устройств пока нет",
                                               systemImage: "lightbulb.slash",
                                               description: Text("Нажмите «Найти устройства» и включите контроллер рядом с телефоном."))
                    } else {
                        ForEach(model.devices) { device in
                            NavigationLink {
                                DeviceDetailScreen(model: model, deviceID: device.id, openLight: openLight)
                            } label: {
                                DeviceRow(model: model, device: device)
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await model.forget(device) } } label: {
                                    Label("Забыть", systemImage: "trash")
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    model.selectTarget(.device(device.id))
                                    openLight()
                                } label: { Label("Свет", systemImage: "paintpalette") }
                                .tint(.blue)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Мои устройства")
                        Spacer()
                        if model.devices.count > 1 {
                            Button("Подключить все") { Task { await model.connectAll() } }
                                .font(.caption.weight(.semibold))
                        }
                    }
                }

                Section {
                    Button {
                        model.toggleScan()
                    } label: {
                        HStack {
                            Label(model.scanning ? "Остановить поиск" : "Найти устройства",
                                  systemImage: model.scanning ? "stop.circle.fill" : "plus.magnifyingglass")
                            Spacer()
                            if model.scanning { ProgressView() }
                        }
                    }
                    .disabled(model.bluetooth == .poweredOff || model.bluetooth == .unauthorized)

                    if model.scanning && model.found.isEmpty {
                        Text("Ищем LED-контроллеры… Убедитесь, что контроллер включён и не подключён к другому телефону.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(model.found) { advertisement in
                        FoundRow(model: model, advertisement: advertisement)
                    }
                    if model.scanning || model.otherDevicesSeen > 0 {
                        Text("Другие Bluetooth-устройства рядом: \(model.otherDevicesSeen)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Добавить")
                } footer: {
                    Text("Поддерживаются Magic Lantern (MELK), Lotus Lantern (ELK/XSL/CLK), LED+LAMP (LEDBLE, LEDDMX, LEDCAR, LEDSMART…) и BLEDIM.")
                }
            }
            .navigationTitle("LED Union")
            .refreshable { await model.reload() }
        }
    }
}

private struct StatusDot: View {
    let phase: LEDConnectionPhase

    var body: some View {
        Circle()
            .fill(phase.tint)
            .frame(width: 10, height: 10)
            .overlay {
                if phase.isBusy {
                    Circle().stroke(phase.tint.opacity(0.5), lineWidth: 2).scaleEffect(1.8)
                        .phaseAnimator([false, true]) { content, on in content.opacity(on ? 0 : 1).scaleEffect(on ? 1.4 : 0.8) }
                }
            }
    }
}

@MainActor
private struct DeviceRow: View {
    @ObservedObject var model: NativeAppModel
    let device: LEDDevice

    var body: some View {
        let phase = model.phase(device.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                StatusDot(phase: phase)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.displayName).font(.body.weight(.medium))
                    Text(phase.title)
                        .font(.caption)
                        .foregroundStyle(phase.tint == .red ? .red : .secondary)
                        .lineLimit(2)
                }
                Spacer()
                if let color = device.lastLook.color, phase.isReady {
                    Circle().fill(color.swiftUIColor).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(.quaternary))
                }
                if phase.isBusy {
                    Button("Отмена") { Task { await model.disconnect(device) } }
                        .buttonStyle(.borderless).font(.caption)
                } else if phase.isReady {
                    Button { Task { await model.disconnect(device) } } label: {
                        Image(systemName: "xmark.circle").font(.title3)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Отключить")
                } else {
                    Button("Подключить") { Task { await model.connect(device) } }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            if let progress = phase.progress {
                ProgressView(value: progress).tint(phase.tint).animation(.easeInOut, value: progress)
            }
        }
        .padding(.vertical, 2)
    }
}

@MainActor
private struct FoundRow: View {
    @ObservedObject var model: NativeAppModel
    let advertisement: BLEAdvertisement

    var body: some View {
        Button {
            Task { await model.connect(advertisement) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: signalIcon).foregroundStyle(.blue).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(advertisement.name).foregroundStyle(.primary)
                    Text("\(DriverRegistry.familyName(for: advertisement.name)) · \(advertisement.rssi) dBm")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Подключить").font(.subheadline.weight(.semibold))
            }
        }
    }

    private var signalIcon: String {
        switch advertisement.rssi {
        case (-60)...: return "wifi"
        case (-75)...: return "wifi.exclamationmark"
        default: return "wifi.slash"
        }
    }
}

@MainActor
private struct DeviceDetailScreen: View {
    @ObservedObject var model: NativeAppModel
    let deviceID: UUID
    let openLight: () -> Void
    @State private var label = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let device = model.devices.first(where: { $0.id == deviceID }) {
            let phase = model.phase(device.id)
            let driver = model.manager.driver(for: device)
            Form {
                Section {
                    HStack {
                        StatusDot(phase: phase)
                        Text(phase.title)
                        Spacer()
                        if phase.isBusy { ProgressView() }
                    }
                    if phase.isReady {
                        Button("Отключить", role: .destructive) { Task { await model.disconnect(device) } }
                    } else if phase.isBusy {
                        Button("Отменить подключение") { Task { await model.disconnect(device) } }
                    } else {
                        Button("Подключить") { Task { await model.connect(device) } }
                    }
                    Button("Управлять светом") {
                        model.selectTarget(.device(device.id))
                        openLight()
                    }
                }
                Section("Название") {
                    TextField(device.advertisedName, text: $label)
                        .submitLabel(.done)
                        .onSubmit { Task { await model.rename(device, to: label) } }
                    Toggle("Подключаться автоматически", isOn: Binding(
                        get: { device.wantsAutoConnect },
                        set: { value in Task { await model.setAutoConnect(device, value) } }
                    ))
                }
                Section("Контроллер") {
                    LabeledContent("Имя в эфире", value: device.advertisedName)
                    LabeledContent("Семейство", value: DriverRegistry.familyName(for: device.advertisedName))
                    LabeledContent("Протокол", value: driver.id)
                    LabeledContent("Возможности", value: capabilityText(driver.capabilities))
                    LabeledContent("Эффектов", value: String(driver.effects.count))
                    if let date = device.lastConnectedAt {
                        LabeledContent("Последнее подключение", value: date.formatted(date: .abbreviated, time: .shortened))
                    }
                    LabeledContent("UUID", value: device.id.uuidString).font(.caption2)
                }
                Section {
                    Button("Забыть устройство", role: .destructive) {
                        Task {
                            await model.forget(device)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(device.displayName)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { label = device.label ?? "" }
            .onDisappear {
                if label != (device.label ?? "") { Task { await model.rename(device, to: label) } }
            }
        } else {
            ContentUnavailableView("Устройство удалено", systemImage: "trash")
        }
    }

    private func capabilityText(_ caps: LEDCapabilities) -> String {
        var parts: [String] = []
        if caps.rgb { parts.append("RGB") }
        if caps.white { parts.append("белый") }
        if caps.cct { parts.append("CCT") }
        if caps.effects { parts.append("эффекты") }
        if caps.scenes { parts.append("сцены") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Target picker

@MainActor
private struct TargetPicker: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        Menu {
            Button {
                model.selectTarget(.all)
            } label: {
                Label("Все устройства", systemImage: model.target == .all ? "checkmark" : "square.grid.2x2")
            }
            Divider()
            ForEach(model.devices) { device in
                Button {
                    model.selectTarget(.device(device.id))
                } label: {
                    Label(device.displayName, systemImage: model.target == .device(device.id) ? "checkmark" : "lightbulb")
                }
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Управляем").font(.caption).foregroundStyle(.secondary)
                    Text(model.targetName).font(.headline).foregroundStyle(.primary)
                }
                Spacer()
                targetStatus
                Image(systemName: "chevron.up.chevron.down").foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var targetStatus: some View {
        let phases = model.targetIDs.map { model.phase($0) }
        let ready = phases.filter(\.isReady).count
        if phases.contains(where: \.isBusy) {
            ProgressView().controlSize(.small)
        } else if !phases.isEmpty {
            Text(ready == phases.count ? "в сети" : "\(ready)/\(phases.count) в сети")
                .font(.caption.weight(.medium))
                .foregroundStyle(ready == phases.count ? .green : .orange)
        }
    }
}

// MARK: - Light

private struct HueSlider: View {
    @Binding var hue: Double
    let onChange: (Double) -> Void
    let onEnd: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 1.0 / 12).map { Color(hue: $0, saturation: 1, brightness: 1) },
                               startPoint: .leading, endPoint: .trailing)
                    .clipShape(Capsule())
                Circle()
                    .fill(Color(hue: hue, saturation: 1, brightness: 1))
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .shadow(radius: 3)
                    .frame(width: 30, height: 30)
                    .offset(x: max(0, min(width - 30, hue * (width - 30))))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let next = max(0, min(1, (value.location.x - 15) / max(1, width - 30)))
                    hue = next
                    onChange(next)
                }
                .onEnded { _ in onEnd() })
        }
        .frame(height: 30)
        .accessibilityLabel("Оттенок")
        .accessibilityValue("\(Int(hue * 360))°")
    }
}

private struct LevelSlider: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var unit = "%"
    let onChange: () -> Void
    let onEnd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text("\(Int(value.rounded()))\(unit)").monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: 1, onEditingChanged: { editing in
                if !editing { onEnd() }
            })
            .onChange(of: value) { _, _ in onChange() }
        }
    }
}

@MainActor
private struct LightScreen: View {
    @ObservedObject var model: NativeAppModel
    @State private var hue: Double = 0
    @State private var dragging = false

    var body: some View {
        NavigationStack {
            List {
                if model.devices.isEmpty {
                    ContentUnavailableView("Нет устройств", systemImage: "lightbulb.slash",
                                           description: Text("Добавьте контроллер на вкладке «Устройства»."))
                } else {
                    Section { TargetPicker(model: model) }

                    Section {
                        HStack(spacing: 16) {
                            powerButton(on: true)
                            powerButton(on: false)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
                    }

                    if model.targetCapabilities.rgb {
                        Section("Цвет") {
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(model.color.swiftUIColor)
                                    .frame(width: 56, height: 56)
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                                    .shadow(color: model.color.swiftUIColor.opacity(0.6), radius: 10)
                                VStack(alignment: .leading) {
                                    Text(model.color.hex).font(.headline.monospaced())
                                    ColorPicker("Палитра", selection: Binding(
                                        get: { model.color.swiftUIColor },
                                        set: { model.liveColor(RGBColor($0)) }
                                    ), supportsOpacity: false)
                                }
                            }
                            HueSlider(hue: $hue,
                                      onChange: { value in model.liveColor(NativeAppModel.hsv(hue: value, saturation: 1, value: 1)) },
                                      onEnd: { Task { await model.finishColorDrag() } })
                                .padding(.vertical, 6)
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 6), spacing: 10) {
                                ForEach(presetColors, id: \.0) { preset in
                                    Button {
                                        Task { await model.pick(preset.1) }
                                    } label: {
                                        Circle().fill(preset.1.swiftUIColor)
                                            .frame(height: 38)
                                            .overlay(Circle().stroke(model.color == preset.1 ? Color.primary : Color.secondary.opacity(0.3),
                                                                     lineWidth: model.color == preset.1 ? 3 : 1))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(preset.0)
                                }
                            }
                            .padding(.vertical, 4)
                            if !model.history.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        Text("Недавние").font(.caption).foregroundStyle(.secondary)
                                        ForEach(model.history, id: \.self) { color in
                                            Button { Task { await model.pick(color) } } label: {
                                                RoundedRectangle(cornerRadius: 6).fill(color.swiftUIColor)
                                                    .frame(width: 28, height: 28)
                                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Section("Яркость") {
                        LevelSlider(title: "Яркость", systemImage: "sun.max.fill", value: $model.brightness,
                                    onChange: { model.liveBrightness() },
                                    onEnd: { Task { await model.finishBrightness() } })
                        if model.targetCapabilities.white {
                            LevelSlider(title: "Белый канал", systemImage: "lightbulb.fill", value: $model.white,
                                        onChange: { model.liveWhite() },
                                        onEnd: { Task { await model.finishWhite() } })
                        }
                        if model.targetCapabilities.cct {
                            LevelSlider(title: "Холодный ↔ тёплый", systemImage: "thermometer.medium", value: $model.warmth,
                                        onChange: { model.liveWarmth() },
                                        onEnd: { Task { await model.finishWarmth() } })
                        }
                    }
                }
            }
            .navigationTitle("Свет")
            .onAppear { hue = model.color.hue }
            .onChange(of: model.color) { _, color in hue = color.hue }
        }
    }

    private func powerButton(on: Bool) -> some View {
        Button {
            Task { await model.setPower(on) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: on ? "lightbulb.fill" : "lightbulb.slash")
                    .font(.title2)
                Text(on ? "Включить" : "Выключить").font(.subheadline.weight(.semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background((model.power == on ? (on ? Color.yellow : Color.gray) : Color.secondary).opacity(model.power == on ? 0.3 : 0.1),
                        in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(model.power == on ? (on ? Color.orange : Color.primary) : Color.secondary)
        }
    }
}

// MARK: - Effects

@MainActor
private struct EffectsScreen: View {
    @ObservedObject var model: NativeAppModel
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if model.devices.isEmpty {
                    ContentUnavailableView("Нет устройств", systemImage: "sparkles",
                                           description: Text("Добавьте контроллер на вкладке «Устройства»."))
                } else {
                    Section { TargetPicker(model: model) }

                    Section {
                        LevelSlider(title: "Скорость", systemImage: "speedometer", value: $model.speed,
                                    onChange: { model.liveSpeed() },
                                    onEnd: { Task { await model.finishSpeed() } })
                    } footer: {
                        Text("Скорость действует на встроенные и программные эффекты.")
                    }

                    if search.isEmpty {
                        Section {
                            Button { Task { await model.toggleMicrophone() } } label: {
                                HStack {
                                    Label(model.micActive ? "Музыка: слушаем микрофон" : "Светомузыка (микрофон)",
                                          systemImage: model.micActive ? "waveform.circle.fill" : "waveform.circle")
                                    Spacer()
                                    if model.micActive { Image(systemName: "stop.fill").foregroundStyle(.red) }
                                }
                            }
                            if model.micActive {
                                LevelSlider(title: "Чувствительность", systemImage: "mic.fill", value: $model.micSensitivity,
                                            range: 0.2...3, unit: "×", onChange: {}, onEnd: {})
                            }
                            ForEach([SoftwareEffect.rainbow, .colorCycle, .breathing, .pulse, .strobe, .candle, .sunset, .ambient, .randomColors], id: \.self) { effect in
                                Button { Task { await model.toggleSoftwareEffect(effect) } } label: {
                                    HStack {
                                        Label(effect.title, systemImage: effect.icon)
                                        Spacer()
                                        if model.softwareEffect == effect {
                                            Image(systemName: "stop.fill").foregroundStyle(.red)
                                        }
                                    }
                                }
                            }
                        } header: {
                            Text("С телефона")
                        } footer: {
                            Text("Эти режимы рассчитываются на iPhone и работают, пока приложение открыто. Микрофон слышит звук в комнате, а не Spotify или Apple Music напрямую.")
                        }
                    }

                    if model.targetHasMixedFamilies {
                        Section {
                            Text("Выбраны контроллеры разных семейств — номера встроенных эффектов у них различаются. Показан список для «\(model.targetDevices.first?.displayName ?? "")».")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }

                    ForEach(filteredGroups) { group in
                        Section(group.group) {
                            ForEach(group.effects, id: \.self) { effect in
                                Button { Task { await model.applyEffect(effect) } } label: {
                                    HStack {
                                        Text(effect.name).foregroundStyle(.primary)
                                        Spacer()
                                        if model.currentEffect?.id == effect.id && model.currentEffect?.group == effect.group {
                                            Image(systemName: "checkmark").foregroundStyle(.tint)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Поиск эффекта")
            .navigationTitle("Эффекты")
        }
    }

    private var filteredGroups: [EffectGroup] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.targetEffects }
        return model.targetEffects.compactMap { group in
            let effects = group.effects.filter { $0.name.localizedCaseInsensitiveContains(query) }
            return effects.isEmpty ? nil : EffectGroup(group: group.group, effects: effects)
        }
    }
}

// MARK: - Scenes

@MainActor
private struct ScenesScreen: View {
    @ObservedObject var model: NativeAppModel
    @State private var naming = false
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        name = "Сцена \(model.scenes.count + 1)"
                        naming = true
                    } label: {
                        Label("Сохранить текущий свет как сцену", systemImage: "plus.circle.fill")
                    }
                    .disabled(model.devices.isEmpty)
                } footer: {
                    Text("Сцена запоминает цвет, яркость и эффект выбранных устройств («\(model.targetName)»). Её можно запускать из Shortcuts и Siri.")
                }

                if model.scenes.isEmpty {
                    ContentUnavailableView("Сцен пока нет", systemImage: "theatermasks")
                } else {
                    Section("Сцены") {
                        ForEach(model.scenes) { scene in
                            Button { Task { await model.applyScene(scene) } } label: {
                                HStack(spacing: 12) {
                                    HStack(spacing: -6) {
                                        ForEach(Array(scene.entries.prefix(4).enumerated()), id: \.offset) { _, entry in
                                            Circle()
                                                .fill(entry.look.power == false ? Color.black : (entry.look.color?.swiftUIColor ?? .white))
                                                .frame(width: 22, height: 22)
                                                .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                                        }
                                    }
                                    VStack(alignment: .leading) {
                                        Text(scene.name).foregroundStyle(.primary)
                                        Text("\(scene.entries.count) устр.").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.fill").foregroundStyle(.tint)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { Task { await model.deleteScene(scene) } } label: {
                                    Label("Удалить", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Сцены")
            .alert("Новая сцена", isPresented: $naming) {
                TextField("Название", text: $name)
                Button("Сохранить") { Task { await model.saveScene(named: name) } }
                Button("Отмена", role: .cancel) {}
            }
        }
    }
}

// MARK: - Diagnostics

@MainActor
private struct DiagnosticsScreen: View {
    @ObservedObject var model: NativeAppModel

    var body: some View {
        NavigationStack {
            List {
                Section("Bluetooth") {
                    LabeledContent("Состояние", value: bluetoothTitle)
                    LabeledContent("Подключено", value: "\(model.connectedCount) из \(model.devices.count)")
                    ForEach(model.devices) { device in
                        LabeledContent(device.displayName, value: model.phase(device.id).title)
                    }
                }
                Section("Журнал") {
                    if model.diagnostics.isEmpty { Text("Пока пусто").foregroundStyle(.secondary) }
                    ForEach(Array(model.diagnostics.enumerated().reversed()), id: \.offset) { _, event in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.kind).font(.caption.weight(.semibold))
                                Spacer()
                                Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if let id = event.deviceID, let device = model.devices.first(where: { $0.id == id }) {
                                Text(device.displayName).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(event.detail).font(.caption.monospaced()).textSelection(.enabled)
                        }
                    }
                }
            }
            .navigationTitle("Журнал")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    ShareLink(item: model.diagnosticsText) { Image(systemName: "square.and.arrow.up") }
                    Button { Task { await model.clearDiagnostics() } } label: { Image(systemName: "trash") }
                }
            }
        }
    }

    private var bluetoothTitle: String {
        switch model.bluetooth {
        case .unknown: return "запуск…"
        case .poweredOn: return "включён"
        case .poweredOff: return "выключен"
        case .unauthorized: return "нет доступа"
        case .unsupported: return "не поддерживается"
        case .resetting: return "перезапуск"
        }
    }
}
#endif
