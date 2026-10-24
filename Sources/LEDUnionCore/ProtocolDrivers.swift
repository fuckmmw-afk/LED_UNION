import Foundation

/// Native port of the frame builders in `src/lib/protocol/`. Every byte here must
/// match the TypeScript drivers, which are the ones checked against the original
/// apps; `Tests/LEDUnionCore/TSFrameFixtures.swift` is generated from them by
/// `tools/difftest/emit_swift_fixtures.ts` and pins the two implementations together.
public protocol LEDProtocolDriver: Sendable {
    var id: String { get }
    var serviceUUID: String { get }
    var writeCharacteristicUUID: String { get }
    var notifyCharacteristicUUID: String? { get }
    var minimumGap: Duration { get }
    var writeWithoutResponse: Bool { get }
    var chunkSize: Int? { get }
    var capabilities: LEDCapabilities { get }
    /// Built-in effects the controller understands, in the original app's order.
    var effects: [LEDEffect] { get }
    /// How long to wait after GATT discovery before the handshake frames.
    var handshakeDelay: Duration { get }
    func onConnect(now: Date) -> [Data]
    func matches(advertisedName: String) -> Bool
    func rgb(_ color: RGBColor) -> Data
    func power(_ on: Bool) -> Data
    func brightness(_ percent: Int) -> Data
    func speed(_ percent: Int) -> Data
    func effect(_ effect: LEDEffect) -> Data
    /// White channel, 0...100. Nil when the family has no white frame.
    func white(_ percent: Int) -> Data?
    /// Colour temperature as warm/cool percentages. Nil when unsupported.
    func cct(warm: Int, cool: Int) -> Data?
}

public extension LEDProtocolDriver {
    var handshakeDelay: Duration { .zero }
    func white(_ percent: Int) -> Data? { nil }
    func cct(warm: Int, cool: Int) -> Data? { nil }
}

public enum DriverRegistry {
    public static let serviceFFF0 = "0000fff0-0000-1000-8000-00805f9b34fb"
    public static let serviceFFE0 = "0000ffe0-0000-1000-8000-00805f9b34fb"
    public static let melk = MELKDriver(name: "MELK-OF21 9D")
    public static let ffe0 = FFE0Driver(name: "LEDBLE-00")
    public static let bledim = BLEDIMDriver(name: "BLEDIM")

    /// Returns true only for names with a known LED Union protocol profile.
    /// Unknown BLE peripherals are kept out of the device chooser so connecting
    /// cannot silently select a driver that does not match the hardware.
    public static func supports(advertisedName name: String) -> Bool {
        bledim.matches(advertisedName: name)
            || melk.matches(advertisedName: name)
            || ffe0.matches(advertisedName: name)
    }

    public static func driver(for name: String) -> any LEDProtocolDriver {
        if bledim.matches(advertisedName: name) { return BLEDIMDriver(name: name) }
        if melk.matches(advertisedName: name) { return MELKDriver(name: name) }
        return FFE0Driver(name: name)
    }

    /// Human readable family label for the device list.
    public static func familyName(for name: String) -> String {
        if bledim.matches(advertisedName: name) { return "BLEDIM" }
        if melk.matches(advertisedName: name) {
            return name.range(of: "^MELK", options: [.regularExpression, .caseInsensitive]) != nil ? "Magic Lantern" : "Lotus Lantern"
        }
        return "LED+LAMP"
    }
}

private func clampedByte(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }
private func clampedPercent(_ value: Int) -> UInt8 { UInt8(max(0, min(100, value))) }
private func nameMatches(_ name: String, _ pattern: String) -> Bool {
    name.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
}

// MARK: - FFF0 (Magic Lantern / Lotus Lantern)

public struct MELKDriver: LEDProtocolDriver {
    public let name: String
    public let id = "fff0-melk"
    public let serviceUUID = DriverRegistry.serviceFFF0
    public let writeCharacteristicUUID = "0000fff3-0000-1000-8000-00805f9b34fb"
    public let notifyCharacteristicUUID: String? = "0000fff4-0000-1000-8000-00805f9b34fb"
    public let minimumGap: Duration = .milliseconds(5)
    public let writeWithoutResponse = true
    public let chunkSize: Int? = nil
    public let capabilities: LEDCapabilities
    private let isMelk: Bool

    public init(name: String) {
        self.name = name
        isMelk = nameMatches(name, "^MELK([-~_ ]|$)")
        self.capabilities = LEDCapabilities(rgb: true,
                                            white: !isMelk || nameMatches(name, "^MELK-.+W"),
                                            cct: !isMelk || nameMatches(name, "^MELK-.+CT"),
                                            speed: true, effects: true, scenes: isMelk)
    }

    public var effects: [LEDEffect] { isMelk ? EffectTables.melk : EffectTables.elk }

    public func matches(advertisedName: String) -> Bool {
        // Some firmware omits the model suffix or uses the documented
        // "LED LIGHT STRIP" local name even though it exposes FFF0/FFF3.
        nameMatches(advertisedName, "^(MELK|ELK|XSL|CLK)([-~_ ]|$)|^LED[ _-]+LIGHT[ _-]+STRIP$")
    }

    public func onConnect(now: Date = .now) -> [Data] { [] }

    public func rgb(_ color: RGBColor) -> Data {
        Data([0x7e, 0x07, 0x05, 0x03, color.red, color.green, color.blue, 0x10, 0xef])
    }

    public func power(_ on: Bool) -> Data {
        let intro = name.range(of: "INTRO", options: .caseInsensitive) != nil
        return Data([0x7e, 0x04, 0x04, on ? (intro ? 0xff : 0x01) : 0x00, 0x00, on ? 0x01 : 0x00, 0xff, 0x00, 0xef])
    }

    public func brightness(_ percent: Int) -> Data {
        Data([0x7e, 0x04, 0x01, clampedPercent(percent), 0xff, 0xff, 0xff, 0x00, 0xef])
    }

    public func speed(_ percent: Int) -> Data {
        Data([0x7e, 0x04, 0x02, clampedPercent(percent), 0xff, 0xff, 0xff, 0x00, 0xef])
    }

    public func effect(_ effect: LEDEffect) -> Data {
        if effect.group == "Scenes" {
            return Data([0x7e, 0x05, 0x31, clampedByte(effect.id), 0x07, 0xff, 0xff, 0x01, 0xef])
        }
        return Data([0x7e, 0x05, 0x03, clampedByte(effect.id), isMelk ? 0x06 : 0x03, 0xff, 0xff, 0x00, 0xef])
    }

    public func white(_ percent: Int) -> Data? {
        Data([0x7e, 0x05, 0x05, 0x01, clampedPercent(percent), 0xff, 0xff, 0x08, 0xef])
    }

    public func cct(warm: Int, cool: Int) -> Data? {
        Data([0x7e, 0x06, 0x05, 0x02, clampedPercent(warm), clampedPercent(cool), 0xff, 0x08, 0xef])
    }
}

// MARK: - FFE0 (LED+LAMP families)

public struct FFE0Driver: LEDProtocolDriver {
    public enum Layout: Sendable { case ble, dmx, shiftedDMX, smart, sun, like, pho }
    public let name: String
    public let id = "ffe0"
    public let serviceUUID = DriverRegistry.serviceFFE0
    public let writeCharacteristicUUID = "0000ffe1-0000-1000-8000-00805f9b34fb"
    public let notifyCharacteristicUUID: String? = nil
    public let minimumGap: Duration = .milliseconds(50)
    public let writeWithoutResponse = true
    public let chunkSize: Int? = nil
    public let capabilities: LEDCapabilities
    public let layout: Layout
    /// The original app sends the `2A` handshake 300 ms after connecting.
    public var handshakeDelay: Duration { .milliseconds(300) }

    private static let f: UInt8 = 0xff
    private var isStage: Bool { nameMatches(name, "^(LEDSTAGE|LEDLIGHT)") }
    private var isCar01: Bool { nameMatches(name, "^LEDCAR-01") }

    public init(name: String) {
        self.name = name
        if nameMatches(name, "^LEDSMART") { layout = .smart }
        else if nameMatches(name, "^LEDSUN") { layout = .sun }
        else if nameMatches(name, "^LEDLIKE") { layout = .like }
        else if nameMatches(name, "^LEDPHO") { layout = .pho }
        else if nameMatches(name, "^(LEDDMX-0[24]|LEDCAR-02)") { layout = .shiftedDMX }
        else if nameMatches(name, "^LEDCAR-01") { layout = .dmx }
        else if nameMatches(name, "^LEDDMX") { layout = .dmx }
        else { layout = .ble }
        let whiteOnly = layout == .sun || layout == .like
        self.capabilities = LEDCapabilities(rgb: !whiteOnly,
                                            white: layout == .shiftedDMX || layout == .smart || whiteOnly,
                                            cct: layout == .sun || layout == .pho || layout == .shiftedDMX || layout == .ble,
                                            speed: true, effects: true, scenes: false)
    }

    public var effects: [LEDEffect] {
        if nameMatches(name, "^LEDCAR-01") { return EffectTables.leddmx }
        if nameMatches(name, "^LEDCAR") { return EffectTables.ledcar }
        switch layout {
        case .dmx, .shiftedDMX: return EffectTables.leddmx
        case .like: return EffectTables.ledlike
        case .pho: return EffectTables.ledpho
        case .smart, .sun: return (0..<16).map { LEDEffect(id: $0, name: "Режим \($0 + 1)") }
        case .ble: return EffectTables.ledble
        }
    }

    public func matches(advertisedName: String) -> Bool {
        nameMatches(advertisedName, "^(LED[_ ]?BLE|LEDSTAGE|LEDLIGHT|LEDDMX|LEDCAR|LEDSMART|LEDSUN|LEDLIKE|LEDPHO)")
    }

    public func onConnect(now: Date = .now) -> [Data] {
        guard nameMatches(name, "^(LEDBLE|LEDDMX|LEDCAR|LED[_ ]BLE)") else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let weekday = calendar.component(.weekday, from: now)
        let weekIndex = weekday == 1 ? 7 : weekday - 1
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return [Data([0x2a, 0x02, 0xa1, 0x23, 0x45, 0x67, UInt8(((weekIndex << 5) | hour) & 0xff), UInt8(minute), 0xaf])]
    }

    public func rgb(_ color: RGBColor) -> Data {
        let F = Self.f
        let (r, g, b) = (color.red, color.green, color.blue)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x07, r, g, b, 0x00, F, F, 0xbf])
        case .dmx: return Data([0x7b, F, 0x07, r, g, b, 0x00, F, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x01, F, r, g, b, F, 0xdf])
        case .pho: return Data([0x72, 0x04, r, g, b, 0x00, 0x00, 0x00, 0x2f])
        case .sun, .like:
            // White-only hardware: drive the white channel by luminance.
            let luminance = (Double(Int(r) + Int(g) + Int(b)) / 3 / 255 * 100).rounded()
            return whiteFrame(Int(luminance))
        case .ble: return Data([0x7e, F, 0x05, 0x03, r, g, b, F, 0xef])
        }
    }

    public func power(_ on: Bool) -> Data {
        let F = Self.f
        let v: UInt8 = on ? 0x01 : 0x00
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x04, v, F, F, F, F, F, 0xbf])
        case .dmx:
            return isCar01 ? Data([0x7b, F, 0x04, v, F, F, F, F, 0xbf]) : Data([0x7b, 0x04, 0x04, v, F, F, F, F, 0xbf])
        case .smart: return Data([0x7d, 0x01, 0x01, v, F, F, F, F, 0xdf])
        case .sun: return Data([0x7a, 0x01, v, F, F, F, F, F, 0xaf])
        case .like: return Data([0x70, 0x01, v, F, F, F, F, F, 0x0f])
        case .pho: return Data([0x72, 0x01, v, 0x00, F, 0x00, 0x00, 0x00, 0x2f])
        case .ble:
            return isStage ? Data([0x7e, F, 0x04, v, F, F, F, F, 0xef]) : Data([0x7e, F, 0x04, v, 0x00, F, F, 0x00, 0xef])
        }
    }

    public func brightness(_ percent: Int) -> Data {
        let F = Self.f
        let b = clampedPercent(percent)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x01, b, 0x00, F, F, F, F, 0xbf])
        case .dmx: return Data([0x7b, F, 0x01, Self.scale32(b), b, 0x00, F, F, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x02, b, F, F, F, F, 0xdf])
        case .sun: return Data([0x7a, 0x02, b, F, F, F, F, F, 0xaf])
        case .like: return Data([0x70, 0x02, b, F, F, F, F, F, 0x0f])
        case .pho: return Data([0x72, 0x02, b, 0x00, F, 0x00, 0x00, 0x00, 0x2f])
        case .ble: return Data([0x7e, F, 0x01, b, 0x00, F, F, F, 0xef])
        }
    }

    public func speed(_ percent: Int) -> Data {
        let F = Self.f
        let s = clampedPercent(percent)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x02, s, 0x00, F, F, F, F, 0xbf])
        case .dmx: return Data([0x7b, F, 0x02, s, F, 0x00, F, F, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x04, s, F, F, F, F, 0xdf])
        case .sun: return Data([0x7a, 0x03, s, F, F, F, F, F, 0xaf])
        case .like: return Data([0x70, 0x03, s, F, F, F, F, F, 0x0f])
        case .pho: return Data([0x72, 0x09, s, F, F, 0x00, 0x00, 0x00, 0x2f])
        case .ble: return Data([0x7e, F, 0x02, s, 0x00, F, F, F, 0xef])
        }
    }

    public func effect(_ effect: LEDEffect) -> Data {
        let F = Self.f
        let id = clampedByte(effect.id)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x03, id, F, F, F, F, F, 0xbf])
        case .dmx: return Data([0x7b, F, 0x03, id, F, F, F, F, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x05, id, F, F, F, F, 0xdf])
        case .sun: return Data([0x7a, 0x06, id, F, F, F, F, F, 0xaf])
        case .like: return Data([0x70, F, id, F, F, F, F, F, 0x0f])
        case .pho: return Data([0x72, 0x08, id, F, F, 0x00, 0x00, 0x00, 0x2f])
        case .ble:
            // setRgbMode; LEDBLE-03 shifts the id one byte left.
            if nameMatches(name, "LEDBLE-03") { return Data([0x7e, 0x03, id, 0x00, F, F, F, F, 0xef]) }
            return Data([0x7e, F, 0x03, id, 0x03, F, F, F, 0xef])
        }
    }

    public func white(_ percent: Int) -> Data? { whiteFrame(percent) }

    public func cct(warm: Int, cool: Int) -> Data? {
        let F = Self.f
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x0a, clampedPercent(cool), F, F, F, F, F, 0xbf])
        case .sun: return Data([0x7a, 0x05, clampedPercent(warm), F, F, F, F, F, 0xaf])
        case .pho: return Data([0x72, 0x05, clampedPercent(warm), F, F, 0x00, 0x00, 0x00, 0x2f])
        default: return Data([0x7e, F, 0x05, 0x02, clampedPercent(warm), clampedPercent(cool), F, F, 0xef])
        }
    }

    private func whiteFrame(_ percent: Int) -> Data {
        let F = Self.f
        let w = clampedPercent(percent)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x09, w, F, F, F, F, F, 0xbf])
        case .dmx: return Data([0x7b, F, 0x09, Self.scale32(w), w, F, F, F, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x07, w, F, F, F, F, 0xdf])
        case .sun: return Data([0x7a, 0x02, w, F, F, F, F, F, 0xaf])
        case .like: return Data([0x70, 0x02, w, F, F, F, F, F, 0x0f])
        case .pho: return Data([0x72, 0x05, w, F, F, 0x00, 0x00, 0x00, 0x2f])
        case .ble: return Data([0x7e, F, 0x05, 0x01, w, F, F, F, 0xef])
        }
    }

    /// The `7B FF` family sends some levels twice: scaled to 0...32, then raw.
    private static func scale32(_ value: UInt8) -> UInt8 {
        UInt8((Double(value) * 32 / 100).rounded())
    }
}

// MARK: - BLEDIM / LanQianTech

public final class BLEDIMDriver: LEDProtocolDriver, @unchecked Sendable {
    public let name: String
    public let id = "bledim"
    public let serviceUUID = DriverRegistry.serviceFFF0
    public let writeCharacteristicUUID = "0000fff1-0000-1000-8000-00805f9b34fb"
    public let notifyCharacteristicUUID: String? = "0000fff1-0000-1000-8000-00805f9b34fb"
    public let minimumGap: Duration = .milliseconds(30)
    public let writeWithoutResponse = false
    public let chunkSize: Int? = 20
    public let capabilities = LEDCapabilities(rgb: true, white: true, cct: false, speed: true, effects: true, scenes: false)
    /// The original app labels the 13 built-in effects M1...M13.
    public let effects: [LEDEffect] = (0..<13).map { LEDEffect(id: $0, name: "M\($0 + 1)") }
    private let lock = NSLock()
    private var sequence: UInt8
    private var currentColor: RGBColor?
    private var currentBrightness: UInt8 = 255
    private var currentSpeed: UInt8 = 192

    public init(name: String, sequence: UInt8 = 0) { self.name = name; self.sequence = sequence }

    public func matches(advertisedName: String) -> Bool {
        nameMatches(advertisedName, "^(BLEDIM|LANQIANTECH)$")
    }

    public func onConnect(now: Date = .now) -> [Data] {
        let calendar = Calendar.current
        return [frame(command: 0x89, payload: [UInt8(calendar.component(.second, from: now)), UInt8(calendar.component(.nanosecond, from: now) / 1_000_000 % 256)])]
    }

    public func rgb(_ color: RGBColor) -> Data {
        let value = withState { () -> [UInt8] in
            currentColor = color
            return staticScene(red: color.red, green: color.green, blue: color.blue, white: 0)
        }
        return frame(command: 0x82, payload: value)
    }

    public func power(_ on: Bool) -> Data { frame(command: 0x80, payload: [on ? 1 : 0]) }

    public func brightness(_ percent: Int) -> Data {
        let (command, payload) = withState { () -> (UInt8, [UInt8]) in
            currentBrightness = Self.from100(percent)
            guard let color = currentColor else { return (0x88, speedBrightness()) }
            let k = Double(currentBrightness) / 255
            func scaled(_ v: UInt8) -> UInt8 { clampedByte(Int((Double(v) * k).rounded())) }
            return (0x82, staticScene(red: scaled(color.red), green: scaled(color.green), blue: scaled(color.blue), white: 0))
        }
        return frame(command: command, payload: payload)
    }

    public func speed(_ percent: Int) -> Data {
        let payload = withState { () -> [UInt8] in
            currentSpeed = Self.from100(percent)
            return speedBrightness()
        }
        return frame(command: 0x88, payload: payload)
    }

    public func effect(_ effect: LEDEffect) -> Data {
        let payload = withState { () -> [UInt8] in
            currentColor = nil
            return sceneFrame(effectID: effect.id)
        }
        return frame(command: 0x82, payload: payload)
    }

    public func white(_ percent: Int) -> Data? {
        frame(command: 0x82, payload: staticScene(red: 0, green: 0, blue: 0, white: Self.from100(percent)))
    }

    private static func from100(_ percent: Int) -> UInt8 {
        UInt8((Double(max(0, min(100, percent))) * 255 / 100).rounded())
    }

    private func withState<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    private func speedBrightness() -> [UInt8] { [0xff, 1, currentSpeed, currentBrightness, 0, 0] }

    private func staticScene(red: UInt8, green: UInt8, blue: UInt8, white: UInt8) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 72)
        payload[1] = 192; payload[2] = 255; payload[3] = 1
        payload[16] = white; payload[17] = red; payload[18] = green; payload[19] = blue
        return payload
    }

    private func sceneFrame(effectID: Int) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 72)
        payload[1] = currentSpeed; payload[2] = currentBrightness; payload[3] = 1
        payload[14] = UInt8(max(0, min(127, effectID))) | 0x80
        payload[17] = 255; payload[18] = 255; payload[19] = 255
        return payload
    }

    public func frame(command: UInt8, payload: [UInt8]) -> Data {
        let currentSequence: UInt8 = withState {
            let value = sequence
            sequence &+= 1
            return value
        }
        var data = Data([0x55, 0xaa, currentSequence, command, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        data.append(contentsOf: payload)
        data.append(data.reduce(UInt8(0)) { $0 &+ $1 })
        return data
    }
}
