import Foundation

public actor SceneManager {
    private let store: LEDStore
    public init(store: LEDStore) { self.store = store }

    @discardableResult
    public func save(name: String, deviceIDs: [UUID]) async throws -> LEDScene {
        let state = await store.snapshot()
        let entries = state.devices.filter { deviceIDs.contains($0.id) }
            .map { LEDScene.Entry(deviceID: $0.id, look: $0.lastLook) }
        let scene = LEDScene(name: name, entries: entries)
        try await store.update { $0.scenes.append(scene) }
        return scene
    }

    public func delete(_ id: UUID) async throws {
        try await store.update { $0.scenes.removeAll { $0.id == id } }
    }

    public func apply(_ id: UUID, send: @escaping @Sendable (UUID, LEDLook) async throws -> Void) async throws {
        guard let scene = (await store.snapshot()).scenes.first(where: { $0.id == id }) else { return }
        for entry in scene.entries { try await send(entry.deviceID, entry.look) }
    }
}
