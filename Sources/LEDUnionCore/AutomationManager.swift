import Foundation

public enum AutomationStatus: String, Sendable { case scheduled, running, cancelled, bestEffort, restoredOnLaunch }

/// Scheduling policy is explicit: only a foreground task has a reliable BLE
/// connection. Background and force-quit execution are recorded as best effort or
/// restore-on-launch instead of being advertised as guaranteed.
public actor AutomationManager {
    private let store: LEDStore
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(store: LEDStore) { self.store = store }

    public func schedule(_ automation: LEDAutomation, perform: @escaping @Sendable () async -> Void) async throws {
        tasks[automation.id]?.cancel()
        let delay = max(0, automation.fireDate.timeIntervalSinceNow)
        tasks[automation.id] = Task {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled else { return }
            await perform()
            if automation.repeats {
                await self.reschedule(automation, perform: perform)
            }
        }
        try await store.update { state in
            if let index = state.automations.firstIndex(where: { $0.id == automation.id }) { state.automations[index] = automation }
            else { state.automations.append(automation) }
        }
    }

    public func cancel(_ id: UUID) async throws {
        tasks.removeValue(forKey: id)?.cancel()
        try await store.update { state in state.automations.removeAll { $0.id == id } }
    }

    public func restoreOnLaunch(perform: @escaping @Sendable (LEDAutomation) async -> Void) async {
        let saved = await store.snapshot().automations
        for automation in saved where automation.guarantee == .restoreOnLaunch {
            await perform(automation)
        }
    }

    private func reschedule(_ automation: LEDAutomation, perform: @escaping @Sendable () async -> Void) async {
        var next = automation
        next.fireDate = Calendar.current.date(byAdding: .day, value: 1, to: automation.fireDate) ?? .now.addingTimeInterval(86_400)
        try? await schedule(next, perform: perform)
    }
}
