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
