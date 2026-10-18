import AppKit
import Observation

/// Folder-open requests arriving from outside the app — the `rafu` CLI
/// launches the bundle via `/usr/bin/open -a` with the folder as a document,
/// and Finder "Open With" does the same. The app delegate enqueues them here;
/// scene roots consume them (the key window wins; a fresh window consumes at
/// startup and skips last-workspace restoration).
@MainActor
@Observable
final class ExternalOpenRequests {
    static let shared = ExternalOpenRequests()

    private(set) var pending: [URL] = []

    func enqueue(_ urls: [URL]) {
        let folders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
        guard !folders.isEmpty else { return }
        pending.append(contentsOf: folders)
    }

    /// Pops the oldest pending folder, or nil. All consumers are MainActor,
    /// so the first window to take a request wins and the rest see nothing.
    func take() -> URL? {
        guard !pending.isEmpty else { return nil }
        return pending.removeFirst()
    }

    var hasPending: Bool { !pending.isEmpty }
}

/// Receives `application(_:open:)` for folders passed by `open -a` (the CLI
/// path) or Finder and routes them to `ExternalOpenRequests`. Also starts the
/// app-level memory-pressure monitor exactly once, at launch, regardless of
/// how many workspace windows subsequently open.
final class RafuAppDelegate: NSObject, NSApplicationDelegate {
    private let terminationPersistence = WorkspaceTerminationPersistence()

    func applicationDidFinishLaunching(_ notification: Notification) {
        CanvasDiagramPanels.registerPaletteItems()  // X9 diagrams
        MemoryPressureMonitor.shared.start()
        LauncherIPCServer.shared.start()
        // Registering the reply-capable notification category and
        // delegate never prompts for permission — safe unconditionally, at
        // launch, before the user has ever enabled or triggered a terminal
        // bell notification (terminal-manager.md T-E). This is the only
        // call into `SystemTerminalAttentionNotifier` from outside
        // `WorkspaceSession`, and it stays free of `import
        // UserNotifications` itself — the static method is the seam.
        SystemTerminalAttentionNotifier.registerCategoryAndDelegate()
        // The resting strip is app-global, not per-window — activate it
        // once at launch (idempotent; a no-op on a non-notch/disabled
        // machine, terminal-notch-hud.md NC-B).
        NotchCompanionModel.shared.activateIfEnabled()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Existing tab-close and empty-window confirmation paths stay in
        // charge of their decisions. This hook first flushes Canvas content,
        // then completes workspace metadata saves.
        // The registry orders the key window first; the helper saves it last.
        let sessions = WorkspaceWindowRegistry.shared.sessionSnapshots().map(\.session)
        terminationPersistence.request(
            sessions: sessions,
            onSaveFailure: {
                sender.reply(toApplicationShouldTerminate: false)
            },
            reply: { sender.reply(toApplicationShouldTerminate: true) }
        )
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        LauncherIPCServer.shared.stop()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // `.rafuensemble` files open as board tabs (X5); folders as before.
        ExternalOpenRequests.shared.enqueue(CanvasEnsembleOpenRouter.shared.route(urls))
        NSApp.activate(ignoringOtherApps: true)
    }
}
