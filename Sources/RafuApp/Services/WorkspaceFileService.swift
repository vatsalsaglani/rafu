import Darwin
import Foundation
import RafuCore

nonisolated struct WorkspaceFileService: Sendable {
    static let maximumEditorBytes = 16 * 1_024 * 1_024
    /// Directories the file tree never descends into. Shared with the
    /// workspace liveness classifier so watching and listing agree.
    static let excludedDirectories: Set<String> = [
        ".git", ".build", ".swiftpm", "dist", "DerivedData", "node_modules",
    ]

    /// Lists exactly one directory level: the workspace root when
    /// `relativeDirectoryPath` is empty, or the directory at that
    /// workspace-relative path otherwise. Never recurses — the sidebar and
    /// index build up their view of the tree by calling this per expanded
    /// or indexed directory instead of loading everything eagerly.
    @concurrent
    func listDirectory(
        rootURL: URL,
        relativeDirectoryPath: String
    ) async throws -> [WorkspaceFileNode] {
        try Task.checkCancellation()
        let directory =
            relativeDirectoryPath.isEmpty
            ? rootURL : rootURL.appending(path: relativeDirectoryPath, directoryHint: .isDirectory)
        return try children(of: directory, rootURL: rootURL)
    }

    @concurrent
    func readText(at url: URL) async throws -> String {
        try Task.checkCancellation()
        // Validate the opened descriptor, not metadata for a path that can
        // change before open. Nonblocking open also prevents a replaced path
        // or a named pipe from blocking before the regular-file check.
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                errno = EINVAL
                return Int32(-1)
            }
            return Darwin.open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard attributes.st_mode & S_IFMT == S_IFREG else {
            throw WorkspaceFileError.notRegularFile
        }
        guard attributes.st_size <= Self.maximumEditorBytes else {
            throw WorkspaceFileError.fileTooLarge(Int(clamping: attributes.st_size))
        }
        let data = try Self.readBoundedData(from: handle)
        try Task.checkCancellation()
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileError.notUTF8
        }
        return text
    }

    /// Read no more than the cap plus one detection byte, even when the file
    /// grows after fstat. No partial document is returned on overflow. The
    /// caller owns and validates the descriptor. Internal for regression tests.
    static func readBoundedData(from handle: FileHandle) throws -> Data {
        var data = Data()
        while true {
            try Task.checkCancellation()
            let count = min(64 * 1_024, maximumEditorBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else {
                return data
            }
            guard chunk.count <= maximumEditorBytes - data.count else {
                throw WorkspaceFileError.fileTooLarge(data.count + chunk.count)
            }
            data.append(chunk)
        }
    }

    @concurrent
    func writeText(_ text: String, to url: URL) async throws {
        try Task.checkCancellation()
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    @concurrent
    func rename(_ url: URL, to newName: String) async throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw WorkspaceFileError.invalidName
        }
        let destination = url.deletingLastPathComponent().appending(path: trimmed)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    @concurrent
    func createItem(in directory: URL, named name: String, isDirectory: Bool) async throws -> URL {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("/") else {
            throw WorkspaceFileError.invalidName
        }
        let destination = directory.appending(
            path: trimmed, directoryHint: isDirectory ? .isDirectory : .notDirectory)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceFileError.itemAlreadyExists(trimmed)
        }
        if isDirectory {
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: false)
        } else {
            guard FileManager.default.createFile(atPath: destination.path, contents: Data()) else {
                throw WorkspaceFileError.couldNotCreate(trimmed)
            }
        }
        return destination
    }

    /// Copies an outside item (Finder drag/paste) into `directory`, choosing a
    /// unique "name", "name 2", … destination instead of overwriting.
    @concurrent
    func importItem(at sourceURL: URL, into directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let destination = Self.uniqueDestination(
            forName: sourceURL.lastPathComponent, in: directory)
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Writes raw data (e.g. a pasted screenshot) to a unique file in
    /// `directory`, never overwriting an existing item.
    @concurrent
    func writeData(_ data: Data, named name: String, into directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let destination = Self.uniqueDestination(forName: name, in: directory)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// Moves a workspace item into another workspace directory (tree
    /// drag-and-drop). Refuses no-op moves, name collisions, and moving a
    /// directory into itself or a descendant.
    @concurrent
    func move(_ sourceURL: URL, into directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let sourcePath = sourceURL.standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        guard directoryPath != sourcePath,
            !directoryPath.hasPrefix(sourcePath + "/")
        else { throw WorkspaceFileError.moveIntoSelf }
        guard sourceURL.deletingLastPathComponent().standardizedFileURL.path != directoryPath
        else { return sourceURL }
        let destination = directory.appending(path: sourceURL.lastPathComponent)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            throw WorkspaceFileError.itemAlreadyExists(sourceURL.lastPathComponent)
        }
        try FileManager.default.moveItem(at: sourceURL, to: destination)
        return destination
    }

    /// Moves workspace items to the Trash (never `removeItem`). A workspace
    /// root and any item outside every root are refused; an item under
    /// another selected folder is skipped, because the folder takes it
    /// along. Stops at the first failure (for example a volume without a
    /// Trash) and reports it with the items already moved, so the caller
    /// can still offer Undo for those.
    @concurrent
    func trash(_ urls: [URL], roots: [WorkspaceRoot]) async -> WorkspaceTrashOutcome {
        var outcome = WorkspaceTrashOutcome()
        for url in Self.topLevelWorkspaceItems(urls, roots: roots) {
            do {
                try Task.checkCancellation()
                var resulting: NSURL?
                try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
                let trashed = (resulting as URL?) ?? url
                outcome.items.append(WorkspaceTrashedItem(original: url, trashed: trashed))
            } catch {
                outcome.failureMessage =
                    "\(url.lastPathComponent) could not be moved to the Trash. "
                    + error.localizedDescription
                break
            }
        }
        return outcome
    }

    /// Undo of `trash`: moves each item back to its original path when that
    /// path is still free. An item whose path is taken stays in the Trash
    /// and is named in the failure message.
    @concurrent
    func restoreFromTrash(_ items: [WorkspaceTrashedItem]) async -> WorkspaceTrashOutcome {
        var outcome = WorkspaceTrashOutcome()
        var skipped: [String] = []
        for item in items {
            guard !FileManager.default.fileExists(atPath: item.original.path),
                FileManager.default.fileExists(atPath: item.trashed.path)
            else {
                skipped.append(item.original.lastPathComponent)
                continue
            }
            do {
                try FileManager.default.moveItem(at: item.trashed, to: item.original)
                outcome.items.append(item)
            } catch {
                skipped.append(item.original.lastPathComponent)
            }
        }
        if !skipped.isEmpty {
            outcome.failureMessage =
                "These items stay in the Trash because their place is taken or they are gone: "
                + skipped.joined(separator: ", ") + "."
        }
        return outcome
    }

    /// The items `trash` and multi-item tree drags act on: no duplicates, no
    /// workspace root, nothing outside the roots, and nothing under another
    /// listed folder. Paths compare after standardization. Order is kept.
    nonisolated static func topLevelWorkspaceItems(_ urls: [URL], roots: [WorkspaceRoot]) -> [URL] {
        let candidates = urls.compactMap { url -> (url: URL, path: String)? in
            let path = WorkspaceRootList.normalizedPath(url.standardizedFileURL.path)
            guard let found = WorkspaceRootList.locate(absolutePath: path, in: roots),
                !found.relativePath.isEmpty
            else { return nil }
            return (url, path)
        }
        let paths = Set(candidates.map(\.path))
        var seen: Set<String> = []
        return candidates.compactMap { candidate in
            let isNested = paths.contains { other in
                other != candidate.path && candidate.path.hasPrefix(other + "/")
            }
            guard !isNested, seen.insert(candidate.path).inserted else { return nil }
            return candidate.url
        }
    }

    /// "name.ext" → "name 2.ext" → "name 3.ext"… until unused.
    nonisolated static func uniqueDestination(forName name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appending(path: name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appending(path: next)
            counter += 1
        }
        return candidate
    }

    private func children(of directory: URL, rootURL: URL) throws -> [WorkspaceFileNode] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants]
        )

        return try urls.compactMap { url in
            if url.lastPathComponent == ".DS_Store" { return nil }
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { return nil }
            let isDirectory = values.isDirectory == true
            if isDirectory, Self.excludedDirectories.contains(url.lastPathComponent) { return nil }
            let relative = String(url.path.dropFirst(rootURL.path.count)).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
            return WorkspaceFileNode(
                url: url,
                relativePath: relative,
                isDirectory: isDirectory
            )
        }
        .sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

/// One item moved to the Trash: where it was, and where the Trash put it.
nonisolated struct WorkspaceTrashedItem: Equatable, Sendable {
    let original: URL
    let trashed: URL
}

/// The result of a Move to Trash or its Undo. `items` lists what moved;
/// `failureMessage` is set when something did not.
nonisolated struct WorkspaceTrashOutcome: Equatable, Sendable {
    var items: [WorkspaceTrashedItem] = []
    var failureMessage: String?
}

enum WorkspaceFileError: LocalizedError {
    case fileTooLarge(Int)
    case invalidName
    case itemAlreadyExists(String)
    case couldNotCreate(String)
    case moveIntoSelf
    case notRegularFile
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            "This file is at least \(bytes) bytes. Rafu’s editor limit is \(WorkspaceFileService.maximumEditorBytes / 1_024 / 1_024) MiB."
        case .invalidName: "Enter a non-empty file name without a slash."
        case .itemAlreadyExists(let name): "An item named \(name) already exists."
        case .couldNotCreate(let name): "Could not create \(name)."
        case .moveIntoSelf: "A folder cannot be moved into itself."
        case .notRegularFile: "This item is not a regular file."
        case .notUTF8: "Rafu's initial editor supports UTF-8 text files."
        }
    }
}
