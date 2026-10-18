import Darwin
import Foundation
import RafuCore

nonisolated struct CanvasLibrary: Sendable {
    var boards: [CanvasSummary] = []
    var unavailableCount = 0
}

/// All disk access and encoding run on this actor, never in a view body.
/// A shared actor plus a nonblocking file lock covers windows and app instances.
actor CanvasPersistenceStore {
    static let shared = CanvasPersistenceStore()
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    nonisolated static func defaultDirectory(identity: RafuAppIdentity = .current) -> URL {
        identity.applicationSupportRoot().appending(path: "Canvases", directoryHint: .isDirectory)
    }

    func list(workspace: TerminalGroupWorkspaceKey) throws -> CanvasLibrary {
        try withLock(workspace: workspace) { folder in
            var result = CanvasLibrary()
            for url in try boardURLs(in: folder) {
                do {
                    let document = try read(url)
                    let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate
                    result.boards.append(
                        .init(
                            id: document.id, title: document.title, revision: document.revision,
                            cardCount: document.cards.count, modified: modified))
                } catch { result.unavailableCount += 1 }
            }
            result.boards.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return result
        }
    }

    func load(_ id: CanvasID, workspace: TerminalGroupWorkspaceKey) throws -> CanvasDocument? {
        try withLock(workspace: workspace) { folder in
            let url = fileURL(id, folder: folder)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let value = try read(url)
            guard value.id == id else { throw CanvasError.invalidDocument }
            return value
        }
    }

    func save(
        _ document: CanvasDocument, expectedRevision: UInt64,
        workspace: TerminalGroupWorkspaceKey
    ) throws -> CanvasDocument {
        try document.validate()
        guard document.revision == expectedRevision, expectedRevision < UInt64.max else {
            throw CanvasError.conflict
        }
        return try withLock(workspace: workspace) { folder in
            let url = fileURL(document.id, folder: folder)
            if FileManager.default.fileExists(atPath: url.path) {
                guard try read(url).revision == expectedRevision else { throw CanvasError.conflict }
            } else {
                guard expectedRevision == 0 else { throw CanvasError.conflict }
                guard try boardURLs(in: folder).count < CanvasLimits.boards else {
                    throw CanvasError.capacity
                }
            }
            var saved = document
            saved.revision = expectedRevision + 1
            let data = try JSONEncoder().encode(saved)
            guard data.count <= CanvasLimits.documentBytes else {
                throw CanvasError.invalidDocument
            }
            try Task.checkCancellation()
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
            return saved
        }
    }

    func delete(
        _ id: CanvasID, expectedRevision: UInt64,
        workspace: TerminalGroupWorkspaceKey
    ) throws {
        try withLock(workspace: workspace) { folder in
            let url = fileURL(id, folder: folder)
            guard try read(url).revision == expectedRevision else { throw CanvasError.conflict }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: url)
        }
    }

    private func fileURL(_ id: CanvasID, folder: URL) -> URL {
        folder.appending(path: id.rawValue.uuidString.lowercased() + ".json")
    }

    private func boardURLs(in folder: URL) throws -> [URL] {
        guard
            let iterator = FileManager.default.enumerator(
                at: folder,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return [] }
        var urls: [URL] = []
        var inspected = 0
        for case let url as URL in iterator {
            inspected += 1
            guard inspected <= 128 else { throw CanvasError.invalidDocument }
            if url.pathExtension == "json",
                UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
            {
                urls.append(url)
                guard urls.count <= CanvasLimits.boards else { throw CanvasError.capacity }
            }
        }
        return urls
    }

    private func read(_ url: URL) throws -> CanvasDocument {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { throw CanvasError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= CanvasLimits.documentBytes
        else { throw CanvasError.invalidDocument }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = CanvasLimits.documentBytes + 1 - data.count
            guard remaining > 0 else { throw CanvasError.invalidDocument }
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)), !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        guard data.count <= CanvasLimits.documentBytes else { throw CanvasError.invalidDocument }
        let value = try JSONDecoder().decode(CanvasDocument.self, from: data)
        try value.validate()
        guard value.revision > 0,
            UUID(uuidString: url.deletingPathExtension().lastPathComponent) == value.id.rawValue
        else { throw CanvasError.invalidDocument }
        return value
    }

    private func withLock<T>(workspace: TerminalGroupWorkspaceKey, _ action: (URL) throws -> T)
        throws -> T
    {
        try Task.checkCancellation()
        let folder = directory.appending(
            path: String(workspace.rawValue.dropFirst(7)), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let lock = folder.appending(path: ".canvas.lock")
        let fd = lock.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600) } ?? -1
        }
        guard fd >= 0 else { throw CanvasError.unavailable }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw CanvasError.busy }
        defer { flock(fd, LOCK_UN) }
        return try action(folder)
    }
}
