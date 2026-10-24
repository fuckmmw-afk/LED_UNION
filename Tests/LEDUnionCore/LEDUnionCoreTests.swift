import Foundation
import Testing
@testable import LEDUnionCore

@Test("MELK RGB frame matches the documented OF21 9D frame")
func melkRGBFrame() {
    let driver = MELKDriver(name: "MELK-OF21 9D")
    #expect(Array(driver.rgb(RGBColor(red: 255, green: 0, blue: 0))) == [0x7e, 0x07, 0x05, 0x03, 0xff, 0x00, 0x00, 0x10, 0xef])
    #expect(Array(driver.rgb(RGBColor(red: 0, green: 255, blue: 0))) == [0x7e, 0x07, 0x05, 0x03, 0x00, 0xff, 0x00, 0x10, 0xef])
    #expect(Array(driver.rgb(RGBColor(red: 0, green: 0, blue: 255))) == [0x7e, 0x07, 0x05, 0x03, 0x00, 0x00, 0xff, 0x10, 0xef])
    #expect(Array(driver.rgb(RGBColor(red: 255, green: 0, blue: 255))) == [0x7e, 0x07, 0x05, 0x03, 0xff, 0x00, 0xff, 0x10, 0xef])
    #expect(Array(driver.rgb(RGBColor(red: 255, green: 255, blue: 255))) == [0x7e, 0x07, 0x05, 0x03, 0xff, 0xff, 0xff, 0x10, 0xef])
}

@Test("CoreBluetooth short and expanded characteristic UUIDs compare equally")
func bluetoothUUIDNormalization() {
    #expect(canonicalBluetoothUUID("FFF3") == "fff3")
    #expect(canonicalBluetoothUUID("0000FFF3-0000-1000-8000-00805F9B34FB") == "fff3")
    #expect(canonicalBluetoothUUID("6E400002-B5A3-F393-E0A9-E50E24DCCA9E") == "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
}

@Test("Driver registry recognises LED advertisements and ignores unrelated BLE names")
func driverRegistryAdvertisementMatching() {
    #expect(DriverRegistry.supports(advertisedName: "MELK-OF21 9D"))
    #expect(DriverRegistry.supports(advertisedName: "MELK"))
    #expect(DriverRegistry.supports(advertisedName: "ELK-BTC"))
    #expect(DriverRegistry.supports(advertisedName: "LED LIGHT STRIP"))
    #expect(DriverRegistry.supports(advertisedName: "LEDBLE-00"))
    #expect(DriverRegistry.supports(advertisedName: "BLEDIM"))
    #expect(!DriverRegistry.supports(advertisedName: "Heart Rate Monitor"))
    #expect(!DriverRegistry.supports(advertisedName: "Unknown LED"))
}

@Test("RGB inputs are clamped to wire byte boundaries")
func rgbClamping() {
    let driver = MELKDriver(name: "MELK-OF21 9D")
    #expect(Array(driver.rgb(RGBColor(red: 500, green: -1, blue: 12))) == [0x7e, 0x07, 0x05, 0x03, 0xff, 0x00, 0x0c, 0x10, 0xef])
}

@Test("BLEDIM packets have the expected checksum")
func bledimChecksum() {
    let packet = BLEDIMDriver(name: "BLEDIM", sequence: 1).frame(command: 0x80, payload: [1])
    #expect(packet.count == 8)
    #expect(packet.last == packet.dropLast().reduce(UInt8(0)) { $0 &+ $1 })
}

@Test("BLEDIM static color is a 72-byte scene and advances sequence")
func bledimStaticScene() {
    let driver = BLEDIMDriver(name: "BLEDIM", sequence: 9)
    let first = driver.rgb(RGBColor(red: 255, green: 0, blue: 128))
    let second = driver.rgb(RGBColor(red: 0, green: 255, blue: 0))
    #expect(first.count == 79)
    #expect(first[3] == 0x82)
    #expect(first[23] == 255 && first[24] == 0 && first[25] == 128)
    #expect(second[2] == 10)
}

@Test("Color engine applies software brightness")
func softwareBrightness() {
    #expect(ColorEngine.applyingBrightness(RGBColor(red: 200, green: 100, blue: 50), percent: 50) == RGBColor(red: 100, green: 50, blue: 25))
}

@Test("Software effect catalog produces cancellable RGB frames")
func softwareEffectCatalog() {
    for effect in SoftwareEffect.allCases {
        #expect(EffectsEngine.frames(effect: effect, steps: 4).count == 4)
    }
}

@Test("JSON store writes atomically and round trips scenes")
func storeRoundTrip() async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("led-union-\(UUID().uuidString).json")
    let store = LEDStore(fileURL: url)
    let id = UUID()
    try await store.update { state in
        state.devices = [LEDDevice(id: id, advertisedName: "MELK-OF21 9D", driverID: "fff0-melk")]
        state.scenes = [LEDScene(name: "Night", entries: [.init(deviceID: id, look: .init(color: .init(red: 1, green: 2, blue: 3)))])]
    }
    let restored = LEDStore(fileURL: url)
    try await restored.load()
    let state = await restored.snapshot()
    #expect(state.scenes.first?.name == "Night")
    #expect(state.scenes.first?.entries.first?.look.color == RGBColor(red: 1, green: 2, blue: 3))
    try? FileManager.default.removeItem(at: url)
}

private actor DataRecorder {
    var values: [Data] = []
    func append(_ value: Data) { values.append(value) }
    func snapshot() -> [Data] { values }
}

@Test("Command queue serializes writes and keeps the newest coalesced value")
func commandQueueCoalescing() async {
    let recorder = DataRecorder()
    let queue = CommandQueue(minimumGap: .milliseconds(1)) { data in
        try? await Task.sleep(for: .milliseconds(2))
        await recorder.append(data)
    }
    await queue.enqueue(Data([0]), coalescingKey: "rgb")
    await queue.enqueue(Data([1]), coalescingKey: "rgb")
    await queue.enqueue(Data([2]), coalescingKey: "rgb")
    await queue.waitUntilIdle()
    let values = await recorder.snapshot()
    #expect(values == [Data([2])])
}

@Test("Command queue cancellation drops a superseded effect")
func commandQueueCancellation() async {
    let recorder = DataRecorder()
    let (release, continuation) = AsyncStream<Void>.makeStream()
    let queue = CommandQueue(minimumGap: .zero) { data in
        if data == Data([0]) {
            for await _ in release { break }
        }
        await recorder.append(data)
    }
    await queue.enqueue(Data([0]))
    await Task.yield()
    await queue.enqueue(Data([1]), coalescingKey: "effect")
    await queue.cancel(coalescingKey: "effect")
    continuation.yield(())
    await queue.waitUntilIdle()
    let values = await recorder.snapshot()
    #expect(values == [Data([0])])
}

private func replay(_ command: String, on driver: any LEDProtocolDriver) -> Data? {
    let parts = command.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    let numbers = parts.count > 1 ? parts[1].split(separator: ",").compactMap { Int($0) } : []
    switch parts[0] {
    case "power": return driver.power(numbers.first == 1)
    case "rgb": return driver.rgb(RGBColor(red: numbers[0], green: numbers[1], blue: numbers[2]))
    case "brightness": return driver.brightness(numbers[0])
    case "speed": return driver.speed(numbers[0])
    case "effect":
        let group = parts.count > 2 && !parts[2].isEmpty ? parts[2] : nil
        return driver.effect(LEDEffect(id: numbers[0], name: "", group: group))
    case "white": return driver.white(numbers[0])
    case "cct": return driver.cct(warm: numbers[0], cool: numbers[1])
    default: return nil
    }
}

@Test("Native drivers emit the same bytes as the TypeScript drivers")
func nativeFramesMatchTypeScript() {
    var drivers: [String: any LEDProtocolDriver] = [:]
    for fixture in tsFrameFixtures {
        // BLEDIM keeps colour/brightness state between calls, so every name replays
        // its whole sequence on one driver instance, exactly like the TS emitter.
        let driver = drivers[fixture.name] ?? DriverRegistry.driver(for: fixture.name)
        drivers[fixture.name] = driver
        var actual = replay(fixture.command, on: driver).map(Array.init)
        var expected = fixture.frame
        if driver is BLEDIMDriver {
            // The packet counter and the checksum covering it are free-running.
            if actual != nil { actual![2] = 0; actual!.removeLast() }
            if expected != nil { expected![2] = 0; expected!.removeLast() }
        }
        #expect(actual == expected, "\(fixture.name) \(fixture.command)")
    }
}

@Test("Native effect tables match the TypeScript tables")
func nativeEffectTablesMatchTypeScript() {
    for (name, ids) in tsEffectIDs {
        #expect(DriverRegistry.driver(for: name).effects.map(\.id) == ids, "\(name)")
    }
}

@Test("Stores written by the previous release still decode")
func legacyStoreDecodes() throws {
    let legacy = """
    {"schemaVersion":1,"devices":[{"id":"6F1D6A43-2D7B-4C55-9D1C-6E1B1E3B7A10","advertisedName":"MELK-OF21 9D",
    "driverID":"fff0-melk","capabilities":{"rgb":true,"white":false,"cct":false,"speed":true,"effects":true,"scenes":true},
    "lastLook":{"color":{"red":1,"green":2,"blue":3}},"connected":true}],
    "groups":[],"scenes":[],"customEffects":[],"automations":[],"palette":[],"history":[],"diagnosticsEnabled":false}
    """
    let state = try JSONDecoder().decode(LEDStoreState.self, from: Data(legacy.utf8))
    let device = try #require(state.devices.first)
    #expect(device.wantsAutoConnect)
    #expect(device.displayName == "MELK-OF21 9D")
    #expect(device.lastLook.white == nil)
}

@Test("Magic Lantern scenes use the scene opcode and effects carry their table")
func melkScenesAndTables() {
    let driver = MELKDriver(name: "MELK-OF21 9D")
    #expect(driver.effects.count == 241)
    let scene = driver.effects.first { $0.group == "Scenes" }!
    #expect(driver.effect(scene)[2] == 0x31)
    #expect(FFE0Driver(name: "LEDBLE-00").effects.first?.id == 135)
}
