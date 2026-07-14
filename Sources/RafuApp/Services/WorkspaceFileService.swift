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
    case notRegularFile
    case notUTF8

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            "This file is \(bytes) bytes. Rafu's initial editor limit is 4 MB."
        case .invalidName: "Enter a non-empty file name without a slash."
        case .itemAlreadyExists(let name): "An item named \(name) already exists."
        case .couldNotCreate(let name): "Could not create \(name)."
        case .notRegularFile: "This item is not a regular file."
        case .notUTF8: "Rafu's initial editor supports UTF-8 text files."
        }
    }
}
