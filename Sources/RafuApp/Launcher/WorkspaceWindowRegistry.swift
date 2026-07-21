import AppKit
import Observation
import RafuCore

/// MainActor registry for the live SwiftUI workspace scenes. Session/window
/// references are weak; stable IDs and registration order make pure routing
/// deterministic while `WindowAccessor` refreshes each entry as state changes.
@MainActor
@Observable
final class WorkspaceWindowRegistry {
    static let shared = WorkspaceWindowRegistry()

    struct Entry {
        let windowID: UUID
        let registrationOrder: Int
        let rootURL: () -> URL?
        let goto: (String, SourceLocation) -> Void
        weak var window: NSWindow?
    }

    private struct PendingGoto {
        let rootPath: String
        let relativePath: String
        let location: SourceLocation
    }

    private struct PendingNewWindowGoto {
        let minimumRegistrationOrder: Int
        let request: PendingGoto
    }

    private(set) var entries: [ObjectIdentifier: Entry] = [:]
    private var nextRegistrationOrder = 0
    private var pendingByWindowID: [UUID: PendingGoto] = [:]
    private var pendingForNewWindow: [PendingNewWindowGoto] = []
    private var openWorkspaceWindowAction: (() -> Void)?

    private init() {}

    /// The `rootURL` parameter remains part of the frozen I0 call signature;
    /// the registry deliberately rebuilds it with a weak session capture so
    /// the closure cannot keep a closed scene alive.
    func register(
        session: WorkspaceSession,
        window: NSWindow,
        rootURL _: @escaping () -> URL?
    ) {
        let key = ObjectIdentifier(session)
        let identity: (UUID, Int)
        if let current = entries[key] {
            identity = (current.windowID, current.registrationOrder)
        } else {
            identity = (UUID(), nextRegistrationOrder)
            nextRegistrationOrder += 1
        }

        entries[key] = Entry(
            windowID: identity.0,
            registrationOrder: identity.1,
            rootURL: { [weak session] in session?.rootURL },
            goto: { [weak session] relativePath, location in
                session?.openFile(atRelativePath: relativePath, selecting: location)
            },
            window: window
        )
        applyPendingGotoIfReady(to: key)
    }

    func deregister(session: WorkspaceSession) {
        let key = ObjectIdentifier(session)
        if let windowID = entries[key]?.windowID {
            pendingByWindowID.removeValue(forKey: windowID)
        }
        entries.removeValue(forKey: key)
    }

    func pruneDeadEntries() {
        let deadIDs = entries.values.compactMap { entry in
            entry.window == nil ? entry.windowID : nil
        }
        entries = entries.filter { $0.value.window != nil }
        for id in deadIDs { pendingByWindowID.removeValue(forKey: id) }
    }

    func snapshots() -> [OpenWorkspaceRoot] {
        pruneDeadEntries()
        return entries.values
            .sorted { lhs, rhs in
                let lhsIsKey = lhs.window?.isKeyWindow == true
                let rhsIsKey = rhs.window?.isKeyWindow == true
                if lhsIsKey != rhsIsKey { return lhsIsKey }
                return lhs.registrationOrder < rhs.registrationOrder
            }
            .map { entry in
                OpenWorkspaceRoot(windowID: entry.windowID, rootURL: entry.rootURL())
            }
    }

    @discardableResult
    func focus(windowID: UUID) -> Bool {
        pruneDeadEntries()
        guard let window = entries.values.first(where: { $0.windowID == windowID })?.window else {
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    /// Session-keyed counterpart to `focus(windowID:)` — used by the notch
    /// HUD's reveal routes, which resolve a terminal session to its owning
    /// `WorkspaceSession` and need that workspace's window forward.
    @discardableResult
    func focus(session: WorkspaceSession) -> Bool {
        pruneDeadEntries()
        guard let window = entries[ObjectIdentifier(session)]?.window else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return true
    }

    @discardableResult
    func goto(windowID: UUID, relativePath: String, location: SourceLocation) -> Bool {
        pruneDeadEntries()
        guard let entry = entries.values.first(where: { $0.windowID == windowID }) else {
            return false
        }
        entry.goto(relativePath, location)
        return focus(windowID: windowID)
    }

    func queueGoto(
        windowID: UUID,
        workspaceRoot: URL,
        relativePath: String,
        location: SourceLocation
    ) {
        pendingByWindowID[windowID] = PendingGoto(
            rootPath: Self.normalizedPath(workspaceRoot),
            relativePath: relativePath,
            location: location
        )
    }

    func queueGotoForNextWindow(
        workspaceRoot: URL,
        relativePath: String,
        location: SourceLocation
    ) {
        pendingForNewWindow.append(
            PendingNewWindowGoto(
                minimumRegistrationOrder: nextRegistrationOrder,
                request: PendingGoto(
                    rootPath: Self.normalizedPath(workspaceRoot),
                    relativePath: relativePath,
                    location: location
                )
            )
        )
    }

    func installOpenWorkspaceWindowAction(_ action: @escaping () -> Void) {
        openWorkspaceWindowAction = action
    }

    @discardableResult
    func openWorkspaceWindow() -> Bool {
        guard let openWorkspaceWindowAction else { return false }
        openWorkspaceWindowAction()
        return true
    }

    private func applyPendingGotoIfReady(to key: ObjectIdentifier) {
        guard let entry = entries[key], let rootURL = entry.rootURL() else { return }
        let rootPath = Self.normalizedPath(rootURL)

        if let pending = pendingByWindowID[entry.windowID], pending.rootPath == rootPath {
            pendingByWindowID.removeValue(forKey: entry.windowID)
            entry.goto(pending.relativePath, pending.location)
            return
        }

        guard
            let index = pendingForNewWindow.firstIndex(where: {
                entry.registrationOrder >= $0.minimumRegistrationOrder
                    && $0.request.rootPath == rootPath
            })
        else { return }
        let pending = pendingForNewWindow.remove(at: index).request
        entry.goto(pending.relativePath, pending.location)
    }

    private static func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
