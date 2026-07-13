import Foundation
import Testing

@testable import RafuApp

@Test("PROBE: recents bookmark round trip")
@MainActor
func probeRecentsRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory.appending(
        path: "rafu-recents-probe-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = RecentWorkspacesStore()
    store.record(url: dir, displayName: "probe")
    defer { store.remove(rootPath: dir.path) }

    guard let entry = store.load().first(where: { $0.rootPath == dir.path }) else {
        print("PROBE: record FAILED — no entry persisted (bookmarkData threw?)")
        return
    }
    print("PROBE: entry persisted, bookmark bytes = \(entry.bookmark.count)")
    do {
        let resolved = try store.resolve(entry)
        print("PROBE: resolved = \(resolved.path)")
        let ok = resolved.startAccessingSecurityScopedResource()
        print("PROBE: startAccessingSecurityScopedResource = \(ok)")
        if ok { resolved.stopAccessingSecurityScopedResource() }
    } catch {
        print("PROBE: resolve THREW: \(error)")
    }
}
