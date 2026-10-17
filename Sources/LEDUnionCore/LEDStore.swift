import Foundation

public enum LEDStoreError: Error, LocalizedError, Sendable {
    case invalidLocation
    public var errorDescription: String? { "LED Union store location is invalid" }
}

/// Codable JSON state shared by SwiftUI, the Capacitor bridge and App Intents.
/// Writes use Data.write(options: .atomic), so a terminated process cannot leave a
/// partially written document behind.
public actor LEDStore {
    public let fileURL: URL
    private var state: LEDStoreState
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, initialState: LEDStoreState = .init()) {
        self.fileURL = fileURL
        self.state = initialState
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    public static func applicationSupport(filename: String = "led-union.json") throws -> LEDStore {
        let fm = FileManager.default
        let base = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("LEDUnion", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        return LEDStore(fileURL: directory.appendingPathComponent(filename))
    }

    public func load() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data = try Data(contentsOf: fileURL)
        var decoded = try decoder.decode(LEDStoreState.self, from: data)
        if decoded.schemaVersion < LEDStoreState.currentSchema { decoded.schemaVersion = LEDStoreState.currentSchema }
        state = decoded
    }

    public func snapshot() -> LEDStoreState { state }

    public func replace(_ next: LEDStoreState, persist: Bool = true) throws {
        state = next
        if persist { try save() }
    }

    public func update(_ body: @Sendable (inout LEDStoreState) -> Void, persist: Bool = true) throws {
        body(&state)
        if persist { try save() }
    }

    public func save() throws {
        let data = try encoder.encode(state)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
    }
}

public actor Diagnostics {
    private var events: [LEDDiagnosticEvent] = []
    private let limit: Int
    public init(limit: Int = 500) { self.limit = limit }
    public func record(_ event: LEDDiagnosticEvent) {
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
    }
    public func history() -> [LEDDiagnosticEvent] { events }
    public func clear() { events.removeAll() }
}
