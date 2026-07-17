import AppKit
import Observation

/// The live workspace windows this app process currently has open, keyed by
/// `WorkspaceSession` identity. Lets a future IPC router (`docs/plans/
/// phases/cli-app-ipc.md`, I3) answer "is a window already showing this
/// folder" and focus it, without holding a strong reference to a session or
/// its window from a socket-listener context. Populated by
/// `WorkspaceSceneRoot`'s appear/disappear hooks starting at I0; not yet
/// consulted by anything — the router lands in a later increment.
@MainActor
@Observable
final class WorkspaceWindowRegistry {
    static let shared = WorkspaceWindowRegistry()

    struct Entry {
        /// Reads the session's current workspace root on demand — a session
        /// can open or close a folder after registration, so this is a live
        /// query, never a cached snapshot.
        let rootURL: () -> URL?
        weak var window: NSWindow?
    }

    private(set) var entries: [ObjectIdentifier: Entry] = [:]

    private init() {}

    /// Registers (or replaces) the entry for `session`. Call once the
    /// scene's window becomes available (`WindowAccessor`'s callback).
    func register(session: WorkspaceSession, window: NSWindow, rootURL: @escaping () -> URL?) {
        entries[ObjectIdentifier(session)] = Entry(rootURL: rootURL, window: window)
    }

    /// Removes `session`'s entry. Call when its scene disappears.
    func deregister(session: WorkspaceSession) {
        entries.removeValue(forKey: ObjectIdentifier(session))
    }

    /// Drops entries whose window has already been deallocated. A window
    /// can close before its scene's `.onDisappear` runs `deregister`, so
    /// callers that read `entries` prune first rather than trusting a weak
    /// reference is still live.
    func pruneDeadEntries() {
        entries = entries.filter { $0.value.window != nil }
    }
}
