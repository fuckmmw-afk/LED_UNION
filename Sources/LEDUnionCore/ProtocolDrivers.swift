import Foundation

public protocol LEDProtocolDriver: Sendable {
    var id: String { get }
    var serviceUUID: String { get }
    var writeCharacteristicUUID: String { get }
    var notifyCharacteristicUUID: String? { get }
    var minimumGap: Duration { get }
    var writeWithoutResponse: Bool { get }
    var chunkSize: Int? { get }
    var capabilities: LEDCapabilities { get }
    func onConnect(now: Date) -> [Data]
    func matches(advertisedName: String) -> Bool
    func rgb(_ color: RGBColor) -> Data
    func power(_ on: Bool) -> Data
    func brightness(_ percent: Int) -> Data
    func speed(_ percent: Int) -> Data
    func effect(_ effect: LEDEffect) -> Data
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
}

private func clampedByte(_ value: Int) -> UInt8 { UInt8(max(0, min(255, value))) }
private func clampedPercent(_ value: Int) -> UInt8 { UInt8(max(0, min(100, value))) }

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

    public init(name: String) {
        self.name = name
        let isMelk = name.range(of: "^MELK-", options: [.regularExpression, .caseInsensitive]) != nil
        self.capabilities = LEDCapabilities(rgb: true, white: !isMelk || name.range(of: "W", options: .caseInsensitive) != nil,
                                            cct: !isMelk || name.range(of: "CT", options: .caseInsensitive) != nil,
                                            speed: true, effects: true, scenes: isMelk)
    }

    public func matches(advertisedName: String) -> Bool {
        advertisedName.range(of: "^(MELK-|ELK[-~_]|XSL-|CLK-)", options: [.regularExpression, .caseInsensitive]) != nil
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
        let opcode: UInt8 = name.range(of: "^MELK-", options: [.regularExpression, .caseInsensitive]) != nil ? 0x06 : 0x03
        return Data([0x7e, 0x05, 0x03, clampedByte(effect.id), opcode, 0xff, 0xff, 0x00, 0xef])
    }
}

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

    public init(name: String) {
        self.name = name
        if name.range(of: "^LEDSMART", options: [.regularExpression, .caseInsensitive]) != nil { layout = .smart }
        else if name.range(of: "^LEDSUN", options: [.regularExpression, .caseInsensitive]) != nil { layout = .sun }
        else if name.range(of: "^LEDLIKE", options: [.regularExpression, .caseInsensitive]) != nil { layout = .like }
        else if name.range(of: "^LEDPHO", options: [.regularExpression, .caseInsensitive]) != nil { layout = .pho }
        else if name.range(of: "^(LEDDMX-0[24]|LEDCAR-02)", options: [.regularExpression, .caseInsensitive]) != nil { layout = .shiftedDMX }
        else if name.range(of: "^LEDCAR-01", options: [.regularExpression, .caseInsensitive]) != nil { layout = .dmx }
        else if name.range(of: "^LEDDMX", options: [.regularExpression, .caseInsensitive]) != nil { layout = .dmx }
        else { layout = .ble }
        let whiteOnly = layout == .sun || layout == .like
        self.capabilities = LEDCapabilities(rgb: !whiteOnly,
                                            white: layout == .shiftedDMX || layout == .smart,
                                            cct: layout == .sun || layout == .pho || layout == .shiftedDMX || layout == .ble,
                                            speed: true, effects: true, scenes: false)
    }

    public func matches(advertisedName: String) -> Bool {
        advertisedName.range(of: "^(LED[_ ]?BLE|LEDSTAGE|LEDLIGHT|LEDDMX|LEDCAR|LEDSMART|LEDSUN|LEDLIKE|LEDPHO)", options: [.regularExpression, .caseInsensitive]) != nil
    }

    public func onConnect(now: Date = .now) -> [Data] {
        let needsAuth = name.range(of: "^(LEDBLE|LEDDMX|LEDCAR|LED[_ ]BLE)", options: [.regularExpression, .caseInsensitive]) != nil
        guard needsAuth else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let weekday = calendar.component(.weekday, from: now)
        let weekIndex = weekday == 1 ? 7 : weekday - 1
        let hour = calendar.component(.hour, from: now)
        let minute = calendar.component(.minute, from: now)
        return [Data([0x2a, 0x02, 0xa1, 0x23, 0x45, 0x67, UInt8((weekIndex << 5) | hour), UInt8(minute), 0xaf])]
    }

    public func rgb(_ color: RGBColor) -> Data {
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x07, color.red, color.green, color.blue, 0x00, 0xff, 0xff, 0xbf])
        case .dmx: return Data([0x7b, 0xff, 0x07, color.red, color.green, color.blue, 0x00, 0xff, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x01, 0xff, color.red, color.green, color.blue, 0xff, 0xdf])
        case .pho: return Data([0x72, 0x04, color.red, color.green, color.blue, 0x00, 0x00, 0x00, 0x2f])
        case .sun, .like:
            let value = UInt8((Int(color.red) + Int(color.green) + Int(color.blue)) / 3 * 100 / 255)
            return white(value)
        case .ble: return Data([0x7e, 0xff, 0x05, 0x03, color.red, color.green, color.blue, 0xff, 0xef])
        }
    }

    public func power(_ on: Bool) -> Data {
        let value: UInt8 = on ? 0x01 : 0x00
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x04, value, 0xff, 0xff, 0xff, 0xff, 0xff, 0xbf])
        case .dmx: return Data([0x7b, 0x04, 0x04, value, 0xff, 0xff, 0xff, 0xff, 0xbf])
        case .smart: return Data([0x7d, 0x01, 0x01, value, 0xff, 0xff, 0xff, 0xff, 0xdf])
        case .sun: return Data([0x7a, 0x01, value, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf])
        case .like: return Data([0x70, 0x01, value, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f])
        case .pho: return Data([0x72, 0x01, value, 0x00, 0xff, 0x00, 0x00, 0x00, 0x2f])
        case .ble: return Data([0x7e, 0xff, 0x04, value, 0x00, 0xff, 0xff, 0x00, 0xef])
        }
    }

    public func brightness(_ percent: Int) -> Data {
        let value = clampedPercent(percent)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x01, value, 0x00, 0xff, 0xff, 0xff, 0xff, 0xbf])
        case .dmx: return Data([0x7b, 0xff, 0x01, UInt8((Int(value) * 32 + 50) / 100), value, 0x00, 0xff, 0xff, 0xbf])
        case .smart: return Data([0x7d, 0x02, 0x02, value, 0xff, 0xff, 0xff, 0xff, 0xdf])
        case .sun: return Data([0x7a, 0x02, value, 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf])
        case .like: return Data([0x70, 0x02, value, 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f])
        case .pho: return Data([0x72, 0x02, value, 0x00, 0xff, 0x00, 0x00, 0x00, 0x2f])
        case .ble: return Data([0x7e, 0xff, 0x01, value, 0x00, 0xff, 0xff, 0xff, 0xef])
        }
    }

    public func speed(_ percent: Int) -> Data {
        let value = clampedPercent(percent)
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x02, value, 0x00, 0xff, 0xff, 0xff, 0xff, 0xbf])
        case .dmx: return Data([0x7b, 0xff, 0x02, value, 0xff, 0x00, 0xff, 0xff, 0xbf])
        case .ble: return Data([0x7e, 0xff, 0x02, value, 0xff, 0xff, 0xff, 0xff, 0xef])
        default: return Data([0x7d, 0x02, 0x03, value, 0xff, 0xff, 0xff, 0xff, 0xdf])
        }
    }

    public func effect(_ effect: LEDEffect) -> Data {
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x03, clampedByte(effect.id), 0xff, 0xff, 0xff, 0xff, 0xff, 0xbf])
        case .dmx: return Data([0x7b, 0xff, 0x03, clampedByte(effect.id), 0xff, 0xff, 0xff, 0xff, 0xbf])
        case .smart: return Data([0x7d, 0x03, clampedByte(effect.id), 0xff, 0xff, 0xff, 0xff, 0xff, 0xdf])
        case .sun: return Data([0x7a, 0x03, clampedByte(effect.id), 0xff, 0xff, 0xff, 0xff, 0xff, 0xaf])
        case .like: return Data([0x70, 0x03, clampedByte(effect.id), 0xff, 0xff, 0xff, 0xff, 0xff, 0x0f])
        case .pho: return Data([0x72, 0x03, clampedByte(effect.id), 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f])
        case .ble: return Data([0x7e, 0xff, 0x03, clampedByte(effect.id), 0xff, 0xff, 0xff, 0xff, 0xef])
        }
    }

    private func white(_ percent: UInt8) -> Data {
        switch layout {
        case .shiftedDMX: return Data([0x7b, 0x09, percent, 0xff, 0xff, 0xff, 0xff, 0xff, 0xbf])
        default: return Data([0x7e, 0xff, 0x05, 0x01, percent, 0xff, 0xff, 0xff, 0xef])
        }
    }
}

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
    private let lock = NSLock()
    private let stateLock = NSLock()
    private var sequence: UInt8
    private var currentColor: RGBColor?
    private var currentBrightness: UInt8 = 255
    private var currentSpeed: UInt8 = 192

    public init(name: String, sequence: UInt8 = 0) { self.name = name; self.sequence = sequence }

    public func matches(advertisedName: String) -> Bool {
        advertisedName.range(of: "^(BLEDIM|LANQIANTECH)$", options: [.regularExpression, .caseInsensitive]) != nil
    }

    public func onConnect(now: Date = .now) -> [Data] {
        let calendar = Calendar.current
        return [frame(command: 0x89, payload: [UInt8(calendar.component(.second, from: now)), UInt8(calendar.component(.nanosecond, from: now) / 1_000_000)])]
    }

    public func rgb(_ color: RGBColor) -> Data {
        stateLock.lock(); currentColor = color; let value = staticScene(red: color.red, green: color.green, blue: color.blue, white: 0); stateLock.unlock()
        return value
    }
    public func power(_ on: Bool) -> Data { frame(command: 0x80, payload: [on ? 1 : 0]) }
    public func brightness(_ percent: Int) -> Data {
        let brightness = UInt8(max(0, min(255, percent * 255 / 100)))
        stateLock.lock(); currentBrightness = brightness; let color = currentColor; let value: Data
        if let color { let scale = Double(brightness) / 255; value = staticScene(red: UInt8(Double(color.red) * scale), green: UInt8(Double(color.green) * scale), blue: UInt8(Double(color.blue) * scale), white: 0) }
        else { value = speedBrightness() }
        stateLock.unlock(); return value
    }
    public func speed(_ percent: Int) -> Data {
        stateLock.lock(); currentSpeed = UInt8(max(0, min(255, percent * 255 / 100))); let value = speedBrightness(); stateLock.unlock(); return value
    }
    public func effect(_ effect: LEDEffect) -> Data {
        stateLock.lock(); currentColor = nil; let value = sceneFrame(effectID: effect.id); stateLock.unlock(); return value
    }

    private func speedBrightness() -> Data {
        frame(command: 0x88, payload: [0xff, 1, currentSpeed, currentBrightness, 0, 0])
    }

    private func staticScene(red: UInt8, green: UInt8, blue: UInt8, white: UInt8) -> Data {
        var payload = [UInt8](repeating: 0, count: 72)
        payload[1] = 192; payload[2] = 255; payload[3] = 1
        payload[16] = white; payload[17] = red; payload[18] = green; payload[19] = blue
        return frame(command: 0x82, payload: payload)
    }

    private func sceneFrame(effectID: Int) -> Data {
        var payload = [UInt8](repeating: 0, count: 72)
        payload[1] = currentSpeed; payload[2] = currentBrightness; payload[3] = 1
        payload[14] = UInt8(max(0, min(127, effectID))) | 0x80
        payload[17] = 255; payload[18] = 255; payload[19] = 255
        return frame(command: 0x82, payload: payload)
    }

    public func frame(command: UInt8, payload: [UInt8]) -> Data {
        lock.lock()
        let currentSequence = sequence
        sequence &+= 1
        lock.unlock()
        var data = Data([0x55, 0xaa, currentSequence, command, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        data.append(contentsOf: payload)
        data.append(data.reduce(UInt8(0)) { $0 &+ $1 })
        return data
    }
}
