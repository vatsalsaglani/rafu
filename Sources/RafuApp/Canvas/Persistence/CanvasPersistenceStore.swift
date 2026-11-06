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
                            cardCount: document.cards.count, modified: modified,
                            silhouette: CanvasBoardSilhouette(cards: document.cards.map(\.rect))))
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
        forgetAttention(id, workspace: workspace)
    }

    // MARK: File-bound boards (X5)

    private nonisolated struct FileBoardRecord: Codable, Equatable, Sendable {
        var id: CanvasID
        var path: String
    }

    nonisolated static let fileBoardIndexLimit = 32

    /// Remembers that board `id` is bound to the workspace `.rafuensemble`
    /// file at `relativePath`, so a restored workspace can reopen its tab. The
    /// index keeps the newest `fileBoardIndexLimit` entries per workspace.
    func rememberFileBoard(
        _ id: CanvasID, relativePath: String, workspace: TerminalGroupWorkspaceKey
    ) throws {
        guard CanvasCardContent.validRelativePath(relativePath) else {
            throw CanvasError.invalidPath
        }
        try withLock(workspace: workspace) { folder in
            var records = readFileBoardIndex(folder).filter {
                $0.id != id && $0.path != relativePath
            }
            records.append(.init(id: id, path: relativePath))
            records = Array(records.suffix(Self.fileBoardIndexLimit))
            let data = try JSONEncoder().encode(records)
            let url = folder.appending(path: Self.fileBoardIndexName)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// The workspace-relative `.rafuensemble` path remembered for `id`.
    func fileBoardPath(_ id: CanvasID, workspace: TerminalGroupWorkspaceKey) throws -> String? {
        try withLock(workspace: workspace) { folder in
            readFileBoardIndex(folder).last { $0.id == id }?.path
        }
    }

    private nonisolated static let fileBoardIndexName = "ensemble-files.index"

    private func readFileBoardIndex(_ folder: URL) -> [FileBoardRecord] {
        let url = folder.appending(path: Self.fileBoardIndexName)
        guard
            let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            size <= 64 * 1_024, let data = try? Data(contentsOf: url),
            let records = try? JSONDecoder().decode([FileBoardRecord].self, from: data)
        else { return [] }
        return Array(
            records.filter { CanvasCardContent.validRelativePath($0.path) }
                .suffix(Self.fileBoardIndexLimit))
    }

    // MARK: Attention sidecar

    /// Durations and dates only, per board and card id. Never a title, a path
    /// or any card text. Lives beside the boards, outside every board file and
    /// every `.rafuensemble` file, so it is never shared by accident.
    private nonisolated struct AttentionFile: Codable, Equatable, Sendable {
        struct Card: Codable, Equatable, Sendable {
            var id: CanvasCardID
            var seconds: Double
            /// Seconds since 1970.
            var lastFocused: Double
        }
        struct Board: Codable, Equatable, Sendable {
            var id: CanvasID
            var cards: [Card]
        }
        var version = 1
        var boards: [Board] = []

        func records(for id: CanvasID) -> CanvasAttention.Records {
            var result: CanvasAttention.Records = [:]
            for card in boards.first(where: { $0.id == id })?.cards ?? [] {
                result[card.id] = CanvasNodeAttention(
                    seconds: card.seconds,
                    lastFocused: Date(timeIntervalSince1970: card.lastFocused))
            }
            return result
        }

        /// Replaces board `id` (removes it when `records` is empty) and keeps
        /// at most `CanvasLimits.boards` boards, the most recently focused first.
        mutating func set(_ saved: CanvasAttention.Records, for id: CanvasID, now: Date) {
            boards.removeAll { $0.id == id }
            if !saved.isEmpty {
                // Whole seconds and tenths keep the file small.
                let cards = saved.map { key, value in
                    Card(
                        id: key, seconds: (value.seconds * 10).rounded() / 10,
                        lastFocused: value.lastFocused.timeIntervalSince1970.rounded())
                }.sorted { $0.id.rawValue.uuidString < $1.id.rawValue.uuidString }
                boards.append(Board(id: id, cards: cards))
            }
            // Other boards age out on the same rule.
            boards = boards.compactMap { board in
                guard board.id != id else { return board }
                let kept = CanvasAttention.pruned(records(for: board.id), live: nil, now: now)
                guard !kept.isEmpty else { return nil }
                return Board(
                    id: board.id,
                    cards: board.cards.filter { kept[$0.id] != nil })
            }
            func newest(_ board: Board) -> Double { board.cards.map(\.lastFocused).max() ?? 0 }
            boards.sort {
                if newest($0) != newest($1) { return newest($0) > newest($1) }
                return $0.id.rawValue.uuidString < $1.id.rawValue.uuidString
            }
            boards = Array(boards.prefix(CanvasLimits.boards))
        }
    }

    nonisolated static let attentionFileName = "ensemble-attention.json"

    /// The saved attention for board `id`, aged and pruned. Never throws: a
    /// missing, corrupt, oversized or locked file is an empty record, so a
    /// board always opens.
    func loadAttention(
        _ id: CanvasID, workspace: TerminalGroupWorkspaceKey, now: Date = Date()
    ) -> CanvasAttention.Records {
        let result = try? withLock(workspace: workspace) { folder in
            CanvasAttention.pruned(readAttentionFile(folder).records(for: id), live: nil, now: now)
        }
        return result ?? [:]
    }

    /// Adds `delta` to board `id`'s saved attention, drops cards not in `live`
    /// and entries that aged out, and writes the sidecar atomically (0600).
    /// Returns the board's saved records, or nil when nothing could be written
    /// (the caller keeps `delta` and tries again later).
    func recordAttention(
        _ id: CanvasID, delta: CanvasAttention.Records, live: Set<CanvasCardID>,
        workspace: TerminalGroupWorkspaceKey, now: Date = Date()
    ) -> CanvasAttention.Records? {
        try? withLock(workspace: workspace) { folder in
            var file = readAttentionFile(folder)
            let merged = CanvasAttention.pruned(
                CanvasAttention.merged(file.records(for: id), adding: delta), live: live, now: now)
            file.set(merged, for: id, now: now)
            try writeAttentionFile(file, in: folder)
            return merged
        }
    }

    /// Forgets board `id` (it was deleted).
    func forgetAttention(_ id: CanvasID, workspace: TerminalGroupWorkspaceKey, now: Date = Date()) {
        try? withLock(workspace: workspace) { folder in
            var file = readAttentionFile(folder)
            guard file.boards.contains(where: { $0.id == id }) else { return }
            file.set([:], for: id, now: now)
            try writeAttentionFile(file, in: folder)
        }
    }

    private func writeAttentionFile(_ file: AttentionFile, in folder: URL) throws {
        let data = try JSONEncoder().encode(file)
        guard data.count <= CanvasLimits.attentionFileBytes else { throw CanvasError.capacity }
        try Task.checkCancellation()
        let url = folder.appending(path: Self.attentionFileName)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// A bounded, non-following read. Anything unusual is an empty file.
    private func readAttentionFile(_ folder: URL) -> AttentionFile {
        let url = folder.appending(path: Self.attentionFileName)
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { return AttentionFile() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
            info.st_size <= CanvasLimits.attentionFileBytes,
            let data = try? handle.read(upToCount: CanvasLimits.attentionFileBytes + 1),
            data.count <= CanvasLimits.attentionFileBytes,
            var file = try? JSONDecoder().decode(AttentionFile.self, from: data),
            file.version == 1
        else { return AttentionFile() }
        file.boards = file.boards.prefix(CanvasLimits.boards).map { board in
            AttentionFile.Board(id: board.id, cards: Array(board.cards.prefix(CanvasLimits.cards)))
        }
        return file
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
