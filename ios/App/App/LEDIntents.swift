#if os(iOS)
import AppIntents
import Foundation
import LEDUnionCore

// Intents live in the app target, not in a Swift package: the Shortcuts action
// picker did not list the app while the intent types were defined in a package
// module, even though the App Shortcut tiles built on them worked.

// Every intent runs in the app process and goes through `LEDRuntime.shared`, the
// same DeviceManager the SwiftUI scene uses. A Shortcut therefore reuses a live
// BLE link when the app already holds one, and otherwise connects in the
// background (the app declares the bluetooth-central background mode), so no
// intent needs to bring the app to the foreground.

// MARK: - Runtime helpers

private struct IntentFailure: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

@MainActor
private enum IntentRuntime {
    static func targets(_ device: DeviceEntity?) async throws -> [UUID] {
        let runtime = LEDRuntime.shared
        await runtime.start()
        let saved = await runtime.store.snapshot().devices
        if let device {
            guard let id = UUID(uuidString: device.id), saved.contains(where: { $0.id == id }) else {
                throw IntentFailure(message: "Устройство «\(device.name)» больше не сохранено в LED Union")
            }
            return [id]
        }
        guard !saved.isEmpty else { throw IntentFailure(message: DeviceManagerError.noDevices.localizedDescription) }
        return saved.map(\.id)
    }

    static func run(_ command: LEDCommand, on device: DeviceEntity?) async throws -> String {
        let ids = try await targets(device)
        let failures = await LEDRuntime.shared.manager.apply(command, to: ids)
        return try summary(ids: ids, failures: failures)
    }

    static func summary(ids: [UUID], failures: [UUID: String]) throws -> String {
        if failures.count == ids.count, let first = failures.values.first {
            throw IntentFailure(message: first)
        }
        if failures.isEmpty { return ids.count == 1 ? "Готово" : "Готово: \(ids.count) устройств" }
        return "Выполнено на \(ids.count - failures.count) из \(ids.count). Не ответили: \(failures.count)"
    }

    static func device(_ id: UUID) async -> LEDDevice? {
        await LEDRuntime.shared.store.snapshot().devices.first { $0.id == id }
    }
}

// MARK: - Entities

public struct DeviceEntity: AppEntity, Sendable, Hashable {
    public var id: String
    public var name: String
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "LED-устройство")
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
    public static let defaultQuery = DeviceQuery()
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct DeviceQuery: EntityQuery {
    public init() {}

    private func all() async -> [DeviceEntity] {
        let store = await MainActor.run { LEDRuntime.shared.store }
        return await store.snapshot().devices.map { DeviceEntity(id: $0.id.uuidString, name: $0.displayName) }
    }

    public func entities(for identifiers: [DeviceEntity.ID]) async throws -> [DeviceEntity] {
        await loadStore()
        return await all().filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [DeviceEntity] {
        await loadStore()
        return await all()
    }

    private func loadStore() async {
        let store = await MainActor.run { LEDRuntime.shared.store }
        // The query can run before the app scene ever started; read the file directly
        // instead of waiting for Bluetooth auto-connect in `LEDRuntime.start()`.
        if await store.snapshot().devices.isEmpty { try? await store.load() }
    }
}

extension DeviceQuery: EntityStringQuery {
    public func entities(matching string: String) async throws -> [DeviceEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = try await suggestedEntities()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

public struct SceneEntity: AppEntity, Sendable, Hashable {
    public var id: String
    public var name: String
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Сцена")
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
    public static let defaultQuery = SceneQuery()
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SceneQuery: EntityQuery {
    public init() {}

    private func all() async -> [SceneEntity] {
        let store = await MainActor.run { LEDRuntime.shared.store }
        if await store.snapshot().devices.isEmpty { try? await store.load() }
        return await store.snapshot().scenes.map { SceneEntity(id: $0.id.uuidString, name: $0.name) }
    }

    public func entities(for identifiers: [SceneEntity.ID]) async throws -> [SceneEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [SceneEntity] { await all() }
}

extension SceneQuery: EntityStringQuery {
    public func entities(matching string: String) async throws -> [SceneEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await all()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

/// A built-in controller effect. The id carries the effect number and its group
/// ("Scenes" selects a different opcode on Magic Lantern), so the frame can be
/// rebuilt without the original table.
public struct EffectEntity: AppEntity, Sendable, Hashable {
    public var id: String
    public var name: String
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Эффект")
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
    public static let defaultQuery = EffectQuery()
    public init(id: String, name: String) { self.id = id; self.name = name }

    init(effect: LEDEffect, family: String?) {
        id = "\(effect.id)|\(effect.group ?? "")"
        name = family.map { "\(effect.name) · \($0)" } ?? effect.name
    }

    var effect: LEDEffect {
        let parts = id.split(separator: "|", omittingEmptySubsequences: false)
        let number = Int(parts.first ?? "") ?? 0
        let group = parts.count > 1 && !parts[1].isEmpty ? String(parts[1]) : nil
        return LEDEffect(id: number, name: name, group: group)
    }
}

public struct EffectQuery: EntityQuery {
    public init() {}

    private func all() async -> [EffectEntity] {
        let store = await MainActor.run { LEDRuntime.shared.store }
        if await store.snapshot().devices.isEmpty { try? await store.load() }
        let devices = await store.snapshot().devices
        var families: [(String, [LEDEffect])] = []
        for device in devices {
            let family = DriverRegistry.familyName(for: device.advertisedName)
            let effects = DriverRegistry.driver(for: device.advertisedName).effects
            if !families.contains(where: { $0.0 == family }) { families.append((family, effects)) }
        }
        let tagged = families.count > 1
        var seen: Set<String> = []
        var result: [EffectEntity] = []
        for (family, effects) in families {
            for effect in effects {
                let entity = EffectEntity(effect: effect, family: tagged ? family : nil)
                if seen.insert(entity.id).inserted { result.append(entity) }
            }
        }
        return result
    }

    public func entities(for identifiers: [EffectEntity.ID]) async throws -> [EffectEntity] {
        let known = await all()
        return identifiers.map { id in known.first { $0.id == id } ?? EffectEntity(id: id, name: "Эффект \(id.split(separator: "|").first ?? "")") }
    }

    public func suggestedEntities() async throws -> [EffectEntity] { await all() }
}

extension EffectQuery: EntityStringQuery {
    public func entities(matching string: String) async throws -> [EffectEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let all = await all()
        guard !query.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

public enum LEDColorPreset: String, AppEnum, Sendable {
    case red, orange, yellow, green, cyan, blue, purple, pink, white, warmWhite

    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Цвет")
    public static let caseDisplayRepresentations: [LEDColorPreset: DisplayRepresentation] = [
        .red: "Красный",
        .orange: "Оранжевый",
        .yellow: "Жёлтый",
        .green: "Зелёный",
        .cyan: "Голубой",
        .blue: "Синий",
        .purple: "Фиолетовый",
        .pink: "Розовый",
        .white: "Белый",
        .warmWhite: "Тёплый белый",
    ]

    public var color: RGBColor {
        switch self {
        case .red: return RGBColor(red: 255, green: 0, blue: 0)
        case .orange: return RGBColor(red: 255, green: 100, blue: 0)
        case .yellow: return RGBColor(red: 255, green: 210, blue: 0)
        case .green: return RGBColor(red: 0, green: 255, blue: 0)
        case .cyan: return RGBColor(red: 0, green: 220, blue: 255)
        case .blue: return RGBColor(red: 0, green: 0, blue: 255)
        case .purple: return RGBColor(red: 150, green: 0, blue: 255)
        case .pink: return RGBColor(red: 255, green: 40, blue: 150)
        case .white: return RGBColor(red: 255, green: 255, blue: 255)
        case .warmWhite: return RGBColor(red: 255, green: 170, blue: 80)
        }
    }
}

// MARK: - Intents

public struct TurnLEDOnIntent: AppIntent {
    public static let title: LocalizedStringResource = "Включить свет"
    public static let description = IntentDescription("Включает LED-контроллер. Без устройства — все сохранённые.")
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Включить \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentRuntime.run(.power(true), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct TurnLEDOffIntent: AppIntent {
    public static let title: LocalizedStringResource = "Выключить свет"
    public static let description = IntentDescription("Выключает LED-контроллер. Без устройства — все сохранённые.")
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Выключить \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentRuntime.run(.power(false), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct ToggleLEDIntent: AppIntent {
    public static let title: LocalizedStringResource = "Переключить свет"
    public static let description = IntentDescription("Включает свет, если он выключен, и наоборот.")
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Переключить \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await Self.toggle(device)
        return .result(dialog: "\(text)")
    }

    @MainActor
    private static func toggle(_ device: DeviceEntity?) async throws -> String {
        let ids = try await IntentRuntime.targets(device)
        var anyOn = false
        for id in ids {
            let power = await IntentRuntime.device(id)?.lastLook.power
            if power ?? true { anyOn = true }
        }
        let text = try await IntentRuntime.run(.power(!anyOn), on: device)
        return anyOn ? "Свет выключен. \(text)" : "Свет включён. \(text)"
    }
}

public struct SetLEDColorIntent: AppIntent {
    public static let title: LocalizedStringResource = "Установить цвет"
    public static let description = IntentDescription("Устанавливает цвет из списка.")
    @Parameter(title: "Цвет", default: .white) public var color: LEDColorPreset
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Цвет \(\.$color) на \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentRuntime.run(.color(color.color), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct SetLEDHexColorIntent: AppIntent {
    public static let title: LocalizedStringResource = "Установить HEX-цвет"
    public static let description = IntentDescription("Устанавливает произвольный цвет в формате #RRGGBB.")
    @Parameter(title: "HEX-цвет", default: "#FF0088") public var hex: String
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public init(device: DeviceEntity?, hex: String) { self.device = device; self.hex = hex }
    public static var parameterSummary: some ParameterSummary { Summary("Цвет \(\.$hex) на \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let color = RGBColor(hex: hex) else { throw $hex.needsValueError("Введите цвет в формате #FF0088") }
        let text = try await IntentRuntime.run(.color(color), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct SetLEDBrightnessIntent: AppIntent {
    public static let title: LocalizedStringResource = "Установить яркость"
    public static let description = IntentDescription("Яркость от 0 до 100 %.")
    @Parameter(title: "Яркость", default: 100, inclusiveRange: (0, 100)) public var brightness: Int
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Яркость \(\.$brightness) на \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentRuntime.run(.brightness(max(0, min(100, brightness))), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct SetLEDSpeedIntent: AppIntent {
    public static let title: LocalizedStringResource = "Скорость эффекта"
    public static let description = IntentDescription("Скорость встроенного эффекта от 0 до 100 %.")
    @Parameter(title: "Скорость", default: 50, inclusiveRange: (0, 100)) public var speed: Int
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Скорость \(\.$speed) на \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentRuntime.run(.speed(max(0, min(100, speed))), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct StartLEDEffectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Запустить эффект"
    public static let description = IntentDescription("Запускает встроенный эффект контроллера.")
    @Parameter(title: "Эффект") public var effect: EffectEntity
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Эффект \(\.$effect) на \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await IntentRuntime.run(.effect(effect.effect), on: device)
        return .result(dialog: "\(text)")
    }
}

public struct StopLEDEffectIntent: AppIntent {
    public static let title: LocalizedStringResource = "Остановить эффект"
    public static let description = IntentDescription("Возвращает последний статичный цвет.")
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Остановить эффект на \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await Self.stop(device)
        return .result(dialog: "\(text)")
    }

    @MainActor
    private static func stop(_ device: DeviceEntity?) async throws -> String {
        let ids = try await IntentRuntime.targets(device)
        var failures: [UUID: String] = [:]
        for id in ids {
            let color = await IntentRuntime.device(id)?.lastLook.color ?? RGBColor(red: 255, green: 255, blue: 255)
            do { try await LEDRuntime.shared.manager.send(.color(color), to: id) }
            catch { failures[id] = error.localizedDescription }
        }
        return try IntentRuntime.summary(ids: ids, failures: failures)
    }
}

public struct ApplyLEDSceneIntent: AppIntent {
    public static let title: LocalizedStringResource = "Применить сцену"
    public static let description = IntentDescription("Восстанавливает сохранённую в приложении сцену.")
    @Parameter(title: "Сцена") public var scene: SceneEntity
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Применить \(\.$scene)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await Self.apply(scene)
        return .result(dialog: "\(text)")
    }

    @MainActor
    private static func apply(_ scene: SceneEntity) async throws -> String {
        let runtime = LEDRuntime.shared
        await runtime.start()
        guard let id = UUID(uuidString: scene.id),
              let saved = await runtime.store.snapshot().scenes.first(where: { $0.id == id }) else {
            throw IntentFailure(message: "Сцена «\(scene.name)» не найдена")
        }
        let failures = try await runtime.manager.applyScene(id)
        return try IntentRuntime.summary(ids: saved.entries.map(\.deviceID), failures: failures)
    }
}

public struct ConnectLEDDeviceIntent: AppIntent {
    public static let title: LocalizedStringResource = "Подключить устройство"
    public static let description = IntentDescription("Устанавливает Bluetooth-соединение заранее.")
    @Parameter(title: "Устройство", description: "Пусто — все устройства") public var device: DeviceEntity?
    public init() {}
    public static var parameterSummary: some ParameterSummary { Summary("Подключить \(\.$device)") }
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let text = try await Self.connect(device)
        return .result(dialog: "\(text)")
    }

    @MainActor
    private static func connect(_ device: DeviceEntity?) async throws -> String {
        let ids = try await IntentRuntime.targets(device)
        var failures: [UUID: String] = [:]
        for id in ids {
            guard let saved = await IntentRuntime.device(id) else { continue }
            do { try await LEDRuntime.shared.manager.connect(id: id, advertisedName: saved.advertisedName) }
            catch { failures[id] = error.localizedDescription }
        }
        return try IntentRuntime.summary(ids: ids, failures: failures)
    }
}

#endif
