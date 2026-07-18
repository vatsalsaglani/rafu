import Foundation

nonisolated struct WorkspaceFileService: Sendable {
    static let maximumEditorBytes = 4 * 1_024 * 1_024
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
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else { throw WorkspaceFileError.notRegularFile }
        if let size = values.fileSize, size > Self.maximumEditorBytes {
            throw WorkspaceFileError.fileTooLarge(size)
        }
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkspaceFileError.notUTF8
        }
        return text
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
            "This file is \(bytes) bytes. Rafu's initial editor limit is 4 MB."
        case .invalidName: "Enter a non-empty file name without a slash."
        case .itemAlreadyExists(let name): "An item named \(name) already exists."
        case .couldNotCreate(let name): "Could not create \(name)."
        case .moveIntoSelf: "A folder cannot be moved into itself."
        case .notRegularFile: "This item is not a regular file."
        case .notUTF8: "Rafu's initial editor supports UTF-8 text files."
        }
    }
}
