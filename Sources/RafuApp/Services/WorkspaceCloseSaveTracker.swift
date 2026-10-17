import Foundation

/// Close saves outlive their windows and sessions. Quit must wait for them
/// even after those windows have left WorkspaceWindowRegistry.
@MainActor
final class WorkspaceCloseSaveTracker {
    static let shared = WorkspaceCloseSaveTracker()

    private var pending: [UUID: Task<Void, Never>] = [:]
    private var registrationID = UUID()
    private var quitBarrierCount = 0
    private let onDrain: @MainActor () -> Void

    init(onDrain: @escaping @MainActor () -> Void = {}) {
        self.onDrain = onDrain
    }

    func track(_ save: Task<Void, Never>?) {
        guard let save else { return }
        // Close creates its MainActor task and registers it without an await.
        // Cancellation here precedes bookmark or preference work in that task.
        // Explicit ordered quit flushes do not pass through this method.
        if quitBarrierCount > 0 { save.cancel() }
        let id = UUID()
        registrationID = id
        pending[id] = save
        Task(name: "Release completed workspace close save") { [weak self] in
            await save.value
            self?.pending[id] = nil
        }
    }

    func beginQuit() {
        quitBarrierCount += 1
    }

    func endQuit() {
        precondition(quitBarrierCount > 0)
        quitBarrierCount -= 1
    }

    /// Await actual save completion, with no timer or status polling. A close
    /// registered during the await is consumed in the next finite batch.
    func drain() async {
        onDrain()
        let batch = pending
        for (id, save) in batch {
            await save.value
            pending[id] = nil
        }
        if !pending.isEmpty { await drain() }
    }

    /// A close can finish during the final live save and leave no pending
    /// task. The registration identity still records it, so reapply the final
    /// live state after that finite batch. Each retry follows real close work.
    func drainBeforeFinalSave(_ finalSave: @escaping @MainActor () async -> Void) async {
        await drain()
        let beforeSave = registrationID
        await finalSave()
        if registrationID != beforeSave { await drainBeforeFinalSave(finalSave) }
    }
}
