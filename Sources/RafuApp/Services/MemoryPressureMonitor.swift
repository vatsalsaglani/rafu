import Dispatch
import Foundation

/// App-level, event-driven memory-pressure source (ADR 0005's memory-bounded
/// posture). macOS posts `.warning`/`.critical` notifications through
/// `DispatchSourceMemoryPressure` — there is no polling here, only a kernel
/// event handler. On pressure, every open window's `WorkspaceSession` drops
/// its newest-N hibernation grace and sheds its filename-index snapshot, the
/// same "release everything eligible now" response
/// `applyRestoredHibernationPlaceholders()` already applies at restore.
///
/// One process-wide monitor (mirrors `ProcessResourceRegistry.shared`) tracks
/// every open window's session in a weak registry: a closed window's session
/// is pruned automatically once nothing else retains it, so windows never
/// need to unregister.
@MainActor
final class MemoryPressureMonitor {
    static let shared = MemoryPressureMonitor()

    private let queue = DispatchQueue(label: "com.rafu.memory-pressure-monitor")
    private var source: DispatchSourceMemoryPressure?
    private let sessions = NSHashTable<WorkspaceSession>.weakObjects()

    private init() {}

    /// Creates and resumes the pressure source exactly once. A
    /// `DispatchSourceMemoryPressure` crashes if `resume()` is called twice
    /// on the same source, so this guards both source creation and the
    /// single `resume()` call — safe to call from every window's launch path
    /// without tracking who called it first.
    func start() {
        guard source == nil else { return }
        let newSource = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: queue)
        // Weak capture avoids a retain cycle: `self.source` strongly owns
        // `newSource`, and `newSource` strongly owns this handler closure —
        // a strong capture of `newSource` here would close the loop.
        newSource.setEventHandler { [weak newSource] in
            guard let event = newSource?.data else { return }
            Task { @MainActor in
                MemoryPressureMonitor.shared.broadcast(event)
            }
        }
        source = newSource
        newSource.resume()
    }

    /// Registers a window's session for pressure broadcasts. Idempotent by
    /// object identity — the weak hash table is a set, so registering the
    /// same session twice (e.g. a re-run `.task`) adds no duplicate entry.
    func register(_ session: WorkspaceSession) {
        sessions.add(session)
    }

    /// The testable seam: a real `DispatchSourceMemoryPressure` event can't
    /// be triggered deterministically in CI, so tests call this directly
    /// instead of waiting on the kernel. Broadcasts to every still-open
    /// window's session.
    func broadcast(_ event: DispatchSource.MemoryPressureEvent) {
        for session in sessions.allObjects {
            session.respondToMemoryPressure()
        }
    }
}
