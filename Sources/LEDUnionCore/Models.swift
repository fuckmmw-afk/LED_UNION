import Foundation

public struct RGBColor: Codable, Hashable, Sendable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init(red: Int, green: Int, blue: Int) {
        self.init(red: UInt8(clamping: red), green: UInt8(clamping: green), blue: UInt8(clamping: blue))
    }

    public init?(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "0x", with: "", options: .caseInsensitive)
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        self.init(red: Int((value >> 16) & 0xff), green: Int((value >> 8) & 0xff), blue: Int(value & 0xff))
    }

    public var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
}

public struct LEDCapabilities: Codable, Hashable, Sendable {
    public var rgb: Bool
    public var white: Bool
    public var cct: Bool
    public var speed: Bool
    public var effects: Bool
    public var scenes: Bool

    public init(rgb: Bool = true, white: Bool = false, cct: Bool = false,
                speed: Bool = true, effects: Bool = true, scenes: Bool = false) {
        self.rgb = rgb; self.white = white; self.cct = cct; self.speed = speed
        self.effects = effects; self.scenes = scenes
    }
}

public struct LEDEffect: Codable, Hashable, Sendable, Identifiable {
    public let id: Int
    public let name: String
    public var group: String?
    public init(id: Int, name: String, group: String? = nil) {
        self.id = id; self.name = name; self.group = group
    }
}

public struct LEDLook: Codable, Hashable, Sendable {
    public var power: Bool?
    public var color: RGBColor?
    public var brightness: Int?
    public var speed: Int?
    public var effect: LEDEffect?
    public var customEffectID: String?
    public init(power: Bool? = nil, color: RGBColor? = nil, brightness: Int? = nil,
                speed: Int? = nil, effect: LEDEffect? = nil, customEffectID: String? = nil) {
        self.power = power; self.color = color; self.brightness = brightness; self.speed = speed
        self.effect = effect; self.customEffectID = customEffectID
    }
}

public struct LEDDevice: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var advertisedName: String
    public var label: String?
    public var driverID: String
    public var capabilities: LEDCapabilities
    public var lastLook: LEDLook
    public var connected: Bool

    public init(id: UUID, advertisedName: String, label: String? = nil, driverID: String,
                capabilities: LEDCapabilities = .init(), lastLook: LEDLook = .init(), connected: Bool = false) {
        self.id = id; self.advertisedName = advertisedName; self.label = label; self.driverID = driverID
        self.capabilities = capabilities; self.lastLook = lastLook; self.connected = connected
    }
}

public struct LEDGroup: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var deviceIDs: [UUID]
    public init(id: UUID = UUID(), name: String, deviceIDs: [UUID]) {
        self.id = id; self.name = name; self.deviceIDs = deviceIDs
    }
}

public struct LEDScene: Codable, Hashable, Sendable, Identifiable {
    public struct Entry: Codable, Hashable, Sendable {
        public let deviceID: UUID
        public var look: LEDLook
        public init(deviceID: UUID, look: LEDLook) { self.deviceID = deviceID; self.look = look }
    }
    public let id: UUID
    public var name: String
    public var entries: [Entry]
    public init(id: UUID = UUID(), name: String, entries: [Entry]) {
        self.id = id; self.name = name; self.entries = entries
    }
}

public struct LEDCustomEffect: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var colors: [RGBColor]
    public var speed: Int
    public var fade: Bool
    public init(id: UUID = UUID(), name: String, colors: [RGBColor], speed: Int = 50, fade: Bool = true) {
        self.id = id; self.name = name; self.colors = colors; self.speed = speed; self.fade = fade
    }
}

public struct LEDAutomation: Codable, Hashable, Sendable, Identifiable {
    public enum Guarantee: String, Codable, Sendable { case foreground, bestEffort, restoreOnLaunch }
    public let id: UUID
    public var name: String
    public var sceneID: UUID?
    public var fireDate: Date
    public var repeats: Bool
    public var guarantee: Guarantee
    public init(id: UUID = UUID(), name: String, sceneID: UUID?, fireDate: Date,
                repeats: Bool = false, guarantee: Guarantee = .bestEffort) {
        self.id = id; self.name = name; self.sceneID = sceneID; self.fireDate = fireDate
        self.repeats = repeats; self.guarantee = guarantee
    }
}

public struct LEDStoreState: Codable, Sendable {
    public static let currentSchema = 1
    public var schemaVersion: Int
    public var devices: [LEDDevice]
    public var groups: [LEDGroup]
    public var scenes: [LEDScene]
    public var customEffects: [LEDCustomEffect]
    public var automations: [LEDAutomation]
    public var palette: [RGBColor]
    public var history: [RGBColor]
    public var lastSelectedDeviceID: UUID?
    public var diagnosticsEnabled: Bool

    public init(schemaVersion: Int = LEDStoreState.currentSchema, devices: [LEDDevice] = [], groups: [LEDGroup] = [],
                scenes: [LEDScene] = [], customEffects: [LEDCustomEffect] = [], automations: [LEDAutomation] = [],
                palette: [RGBColor] = [], history: [RGBColor] = [], lastSelectedDeviceID: UUID? = nil,
                diagnosticsEnabled: Bool = false) {
        self.schemaVersion = schemaVersion; self.devices = devices; self.groups = groups; self.scenes = scenes
        self.customEffects = customEffects; self.automations = automations; self.palette = palette; self.history = history
        self.lastSelectedDeviceID = lastSelectedDeviceID; self.diagnosticsEnabled = diagnosticsEnabled
    }
}

public enum LEDTransportState: String, Codable, Sendable { case idle, scanning, connecting, connected, disconnected, failed }

public struct BLEAdvertisement: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let rssi: Int
    public let serviceUUIDs: [String]
    public init(id: UUID, name: String, rssi: Int, serviceUUIDs: [String] = []) {
        self.id = id; self.name = name; self.rssi = rssi; self.serviceUUIDs = serviceUUIDs
    }
}

public struct LEDDiagnosticEvent: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let deviceID: UUID?
    public let kind: String
    public let detail: String
    public init(timestamp: Date = .now, deviceID: UUID? = nil, kind: String, detail: String) {
        self.timestamp = timestamp; self.deviceID = deviceID; self.kind = kind; self.detail = detail
    }
}
