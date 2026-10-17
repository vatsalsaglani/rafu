import Foundation

nonisolated enum EditorHoverTiming {
    static let documentationDelay = Duration.milliseconds(150)
}

/// One request per identifier while the pointer remains on it. Cancellation
/// rejects late server results without retaining the editor during a request.
@MainActor
final class EditorHoverRequestScheduler {
    private var target: NSRange?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private let wait: @Sendable (Duration) async throws -> Void

    init(
        wait: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.wait = wait
    }

    deinit { task?.cancel() }

    @discardableResult
    func schedule(
        target nextTarget: NSRange,
        resolve: @escaping @MainActor () async -> EditorHoverInfo?,
        present: @escaping @MainActor (EditorHoverInfo) -> Void
    ) -> Task<Void, Never>? {
        guard target != nextTarget else { return task }
        cancel()
        target = nextTarget
        let requestGeneration = generation
        task = Task { [weak self, wait] in
            defer {
                if self?.generation == requestGeneration { self?.task = nil }
            }
            do {
                try await wait(EditorHoverTiming.documentationDelay)
                try Task.checkCancellation()
            } catch { return }
            guard self?.generation == requestGeneration else { return }
            let info = await resolve()
            guard !Task.isCancelled, self?.generation == requestGeneration else { return }
            guard let info else {
                self?.target = nil
                return
            }
            present(info)
        }
        return task
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        target = nil
    }
}
