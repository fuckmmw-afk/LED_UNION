import Foundation

public actor GroupManager {
    private let store: LEDStore
    public init(store: LEDStore) { self.store = store }

    @discardableResult
    public func create(name: String, deviceIDs: [UUID]) async throws -> LEDGroup {
        let group = LEDGroup(name: name, deviceIDs: deviceIDs)
        try await store.update { $0.groups.append(group) }
        return group
    }

    public func rename(_ id: UUID, to name: String) async throws {
        try await store.update { state in
            guard let index = state.groups.firstIndex(where: { $0.id == id }) else { return }
            state.groups[index].name = name
        }
    }

    public func delete(_ id: UUID) async throws {
        try await store.update { $0.groups.removeAll { $0.id == id } }
    }

    public func members(_ id: UUID) async -> [UUID] {
        let state = await store.snapshot()
        return state.groups.first(where: { $0.id == id })?.deviceIDs ?? []
    }
}
