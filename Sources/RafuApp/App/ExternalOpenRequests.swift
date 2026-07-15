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
    func applicationDidFinishLaunching(_ notification: Notification) {
        MemoryPressureMonitor.shared.start()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        ExternalOpenRequests.shared.enqueue(urls)
        NSApp.activate(ignoringOtherApps: true)
    }
}
