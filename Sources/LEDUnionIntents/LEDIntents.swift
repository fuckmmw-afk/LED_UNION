#if os(iOS)
import AppIntents
import Foundation
import LEDUnionCore

@MainActor
public enum LEDAppRuntime {
    public static func makeStore() -> LEDStore {
        LEDStore(fileURL: URL.applicationSupportDirectory.appendingPathComponent("LEDUnion/led-union.json"))
    }

    /// App Intents runs in a separate system invocation and must load the same
    /// atomic JSON state that the native SwiftUI app writes.
    public static func loadedStore() async -> LEDStore {
        let store = makeStore()
        try? await store.load()
        return store
    }

    public static func loadedManager() async -> DeviceManager {
        let store = await loadedStore()
        return DeviceManager(store: store)
    }

    public static func load() async {
        _ = await loadedStore()
    }
}

public struct DeviceEntity: AppEntity, Sendable, Hashable {
    public var id: String
    public var name: String
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "LED device")
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
    public static let defaultQuery = DeviceQuery()
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct DeviceQuery: EntityQuery {
    public init() {}
    public func entities(for identifiers: [DeviceEntity.ID]) async throws -> [DeviceEntity] {
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        return state.devices.compactMap { device in
            guard identifiers.contains(device.id.uuidString) else { return nil }
            return DeviceEntity(id: device.id.uuidString, name: device.label ?? device.advertisedName)
        }
    }
    public func suggestedEntities() async throws -> [DeviceEntity] {
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        return state.devices.map { DeviceEntity(id: $0.id.uuidString, name: $0.label ?? $0.advertisedName) }
    }
}

extension DeviceQuery: EntityStringQuery {
    public func entities(matching string: String) async throws -> [DeviceEntity] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return try await suggestedEntities() }
        return try await suggestedEntities().filter { $0.name.localizedCaseInsensitiveContains(query) }
    }
}

public struct SceneEntity: AppEntity, Sendable, Hashable {
    public var id: String
    public var name: String
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "LED scene")
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
    public static let defaultQuery = SceneQuery()
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct SceneQuery: EntityQuery {
    public init() {}
    public func entities(for identifiers: [SceneEntity.ID]) async throws -> [SceneEntity] {
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        return state.scenes.compactMap { identifiers.contains($0.id.uuidString) ? SceneEntity(id: $0.id.uuidString, name: $0.name) : nil }
    }
    public func suggestedEntities() async throws -> [SceneEntity] {
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        return state.scenes.map { SceneEntity(id: $0.id.uuidString, name: $0.name) }
    }
}

public struct EffectEntity: AppEntity, Sendable, Hashable {
    public var id: String
    public var name: String
    public static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "LED effect")
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: LocalizedStringResource(stringLiteral: name)) }
    public static let defaultQuery = EffectQuery()
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct EffectQuery: EntityQuery {
    public init() {}
    private func builtIns() -> [EffectEntity] {
        (0..<32).map { EffectEntity(id: String($0), name: "Effect \($0)") }
    }
    public func entities(for identifiers: [EffectEntity.ID]) async throws -> [EffectEntity] {
        builtIns().filter { identifiers.contains($0.id) }
    }
    public func suggestedEntities() async throws -> [EffectEntity] { builtIns() }
}

private enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case deviceMissing
    var localizedStringResource: LocalizedStringResource { "Choose a saved LED device" }
}

private func deviceID(_ entity: DeviceEntity) throws -> UUID {
    guard let id = UUID(uuidString: entity.id) else { throw IntentError.deviceMissing }
    return id
}

public struct SetLEDColorIntent: AppIntent {
    public static let title = LocalizedStringResource("Set LED color")
    public static let description = IntentDescription("Set an LED controller to an RGB or HEX color.")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    @Parameter(title: "HEX color") public var hex: String
    public init() {}
    public init(device: DeviceEntity, hex: String) { self.device = device; self.hex = hex }
    public func perform() async throws -> some IntentResult {
        guard let color = RGBColor(hex: hex) else { throw $hex.needsValueError("Enter a color like #FF0088") }
        let manager = await LEDAppRuntime.loadedManager()
        try await manager.send(.color(color), to: deviceID(device), coalescingKey: "color")
        return .result()
    }
}

public struct SetLEDBrightnessIntent: AppIntent {
    public static let title = LocalizedStringResource("Set LED brightness")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    @Parameter(title: "Brightness") public var brightness: Int
    public init() {}
    public func perform() async throws -> some IntentResult {
        let manager = await LEDAppRuntime.loadedManager()
        try await manager.send(.brightness(max(0, min(100, brightness))), to: deviceID(device), coalescingKey: "brightness")
        return .result()
    }
}

public struct ApplyLEDSceneIntent: AppIntent {
    public static let title = LocalizedStringResource("Apply LED scene")
    public static let openAppWhenRun = true
    @Parameter(title: "Scene") public var scene: SceneEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        guard let saved = state.scenes.first(where: { $0.id.uuidString == scene.id }) else { throw IntentError.deviceMissing }
        let manager = await LEDAppRuntime.loadedManager()
        for entry in saved.entries {
            if let color = entry.look.color { try? await manager.send(.color(color), to: entry.deviceID, coalescingKey: "scene-color") }
            if let brightness = entry.look.brightness { try? await manager.send(.brightness(brightness), to: entry.deviceID, coalescingKey: "scene-brightness") }
            if let power = entry.look.power { try? await manager.send(.power(power), to: entry.deviceID) }
        }
        return .result()
    }
}

public struct StartLEDEffectIntent: AppIntent {
    public static let title = LocalizedStringResource("Start LED effect")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    @Parameter(title: "Effect") public var effect: EffectEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let id = try deviceID(device)
        let numericID = Int(effect.id) ?? 0
        let manager = await LEDAppRuntime.loadedManager()
        try await manager.send(.effect(LEDEffect(id: numericID, name: effect.name)), to: id)
        return .result()
    }
}

public struct StopLEDEffectIntent: AppIntent {
    public static let title = LocalizedStringResource("Stop LED effect")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let id = try deviceID(device)
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        let manager = await LEDAppRuntime.loadedManager()
        if let color = state.devices.first(where: { $0.id == id })?.lastLook.color {
            try await manager.send(.color(color), to: id, coalescingKey: "effect-stop")
        } else {
            try await manager.send(.power(true), to: id)
        }
        return .result()
    }
}

public struct TurnLEDOnIntent: AppIntent {
    public static let title = LocalizedStringResource("Turn LED on")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let manager = await LEDAppRuntime.loadedManager()
        try await manager.send(.power(true), to: deviceID(device))
        return .result()
    }
}

public struct TurnLEDOffIntent: AppIntent {
    public static let title = LocalizedStringResource("Turn LED off")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let manager = await LEDAppRuntime.loadedManager()
        try await manager.send(.power(false), to: deviceID(device))
        return .result()
    }
}

public struct ConnectLEDDeviceIntent: AppIntent {
    public static let title = LocalizedStringResource("Connect LED device")
    public static let openAppWhenRun = true
    @Parameter(title: "Device") public var device: DeviceEntity
    public init() {}
    public func perform() async throws -> some IntentResult {
        let store = await LEDAppRuntime.loadedStore()
        let state = await store.snapshot()
        guard let saved = state.devices.first(where: { $0.id.uuidString == device.id }) else { throw IntentError.deviceMissing }
        let manager = await LEDAppRuntime.loadedManager()
        try await manager.connect(id: saved.id, advertisedName: saved.advertisedName)
        return .result()
    }
}

public struct LEDAppShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: TurnLEDOnIntent(), phrases: ["Turn on lights in \(.applicationName)"], shortTitle: "Turn on", systemImageName: "lightbulb.fill")
        AppShortcut(intent: TurnLEDOffIntent(), phrases: ["Turn off lights in \(.applicationName)"], shortTitle: "Turn off", systemImageName: "lightbulb")
        AppShortcut(intent: ApplyLEDSceneIntent(), phrases: ["Apply a scene in \(.applicationName)"], shortTitle: "Apply scene", systemImageName: "sparkles")
    }
}
#endif
