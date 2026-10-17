import Foundation

/// One complete post-edit snapshot. A missing edit means the old tree must be
/// discarded. Coalescing must never keep an edit relative to a skipped snapshot.
nonisolated struct SyntaxSnapshotRequest: Sendable {
    nonisolated struct Edit: Sendable {
        let startUTF16: Int
        let oldEndUTF16: Int
        let newEndUTF16: Int
    }

    let text: String
    let version: Int
    let edit: Edit?

    var fullReset: Self { Self(text: text, version: version, edit: nil) }
}

/// Bridges synchronous storage edits to one parser operation at a time. At most
/// one snapshot waits beside the active operation. No task retains a predecessor.
@MainActor
final class SyntaxSnapshotWorker {
    nonisolated struct Metrics: Sendable, Equatable {
        var pendingCount = 0
        var activeCount = 0
        var peakPendingCount = 0
        var peakRetainedSnapshotCount = 0
        var coalescedSnapshotCount = 0
        var fullResetCount = 0
        var completedCount = 0
    }

    private let operation: @Sendable (SyntaxSnapshotRequest) async -> Void
    private let didFinish: @MainActor (Int) -> Void
    private var pending: SyntaxSnapshotRequest?
    private var task: Task<Void, Never>?
    private var isStopped = false
    private var latestVersion = 0
    private(set) var metrics = Metrics()

    init(
        operation: @escaping @Sendable (SyntaxSnapshotRequest) async -> Void,
        didFinish: @escaping @MainActor (Int) -> Void
    ) {
        self.operation = operation
        self.didFinish = didFinish
    }

    deinit { task?.cancel() }

    func submit(_ request: SyntaxSnapshotRequest) {
        guard !isStopped, request.version > latestVersion else { return }
        latestVersion = request.version
        if pending != nil {
            pending = request.fullReset
            metrics.coalescedSnapshotCount += 1
        } else {
            pending = request
        }
        metrics.pendingCount = 1
        metrics.peakPendingCount = max(metrics.peakPendingCount, metrics.pendingCount)
        metrics.peakRetainedSnapshotCount = max(
            metrics.peakRetainedSnapshotCount, metrics.pendingCount + metrics.activeCount)
        recordQueue()
        guard task == nil else { return }
        let operation = operation
        task = Task { [weak self] in
            defer { self?.workerDidStop() }
            // This drains owned work; it does not poll or wait for external state.
            while let request = self?.takePending() {
                guard !Task.isCancelled else { return }
                await operation(request)
                guard !Task.isCancelled else { return }
                self?.finished(request.version)
            }
        }
    }

    func stop() {
        isStopped = true
        pending = nil
        metrics.pendingCount = 0
        task?.cancel()
        // Keep the handle until completion so callers can await the actual stop.
        recordQueue()
    }

    /// Await owned work directly. No timer or scheduler-dependent test delay.
    func waitUntilIdle() async {
        await task?.value
    }

    private func takePending() -> SyntaxSnapshotRequest? {
        guard !isStopped, let request = pending else { return nil }
        pending = nil
        metrics.pendingCount = 0
        metrics.activeCount = 1
        if request.edit == nil { metrics.fullResetCount += 1 }
        recordQueue()
        return request
    }

    private func finished(_ version: Int) {
        guard !isStopped else { return }
        metrics.activeCount = 0
        metrics.completedCount += 1
        recordQueue()
        // An older parse can update the actor, but cannot mark editor ranges valid.
        guard version == latestVersion else { return }
        didFinish(version)
    }

    private func workerDidStop() {
        metrics.activeCount = 0
        task = nil
        recordQueue()
    }

    private func recordQueue() {
        SyntaxSignpost.recordQueue(
            pending: metrics.pendingCount, active: metrics.activeCount,
            coalesced: metrics.coalescedSnapshotCount,
            resets: metrics.fullResetCount)
    }
}
