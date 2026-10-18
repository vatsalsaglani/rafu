import Darwin
import Foundation

/// Where a file-bound board lives and what Rafu last saw there.
nonisolated struct CanvasEnsembleFileBinding: Equatable, Sendable {
    /// Workspace-relative path of the `.rafuensemble` file.
    var relativePath: String
    /// `CanvasEnsembleFile.fingerprint` of the bytes Rafu last read or wrote.
    var fingerprint: UInt64
}

/// One read of a `.rafuensemble` file.
nonisolated struct CanvasEnsembleFileSnapshot: Sendable {
    var document: CanvasDocument
    var binding: CanvasEnsembleFileBinding
    /// Embedded images whose workspace path does not exist (yet).
    var missingEmbeddedImages: [String: Data]
}

/// All `.rafuensemble` disk access runs on this actor, never in a view body.
///
/// Writes are atomic (`Data.write(options: .atomic)`) and use an expected
/// version check: before replacing a bound file, the actor re-reads it and
/// refuses with `CanvasError.conflict` unless both the stored revision and the
/// byte fingerprint still match what this board last saw. That catches a
/// second window and an outside change (a Git checkout, another editor) that
/// does not touch the revision. The check-then-replace window is not locked
/// across processes; it is the same small window the App Support store
/// accepts for files a user can edit outside Rafu.
actor CanvasEnsembleFileStore {
    static let shared = CanvasEnsembleFileStore()

    init() {}

    /// Reads and validates the file at `relativePath` inside `root`.
    func read(relativePath: String, root: URL) throws -> CanvasEnsembleFileSnapshot {
        let url = try Self.checkedFileURL(relativePath, root: root)
        let data = try Self.readBytes(url)
        let file = try CanvasEnsembleFile.decode(data)
        let document = try file.document()
        var missing: [String: Data] = [:]
        for (path, bytes) in file.embeddedImages {
            guard let target = try? CanvasPreviewLoader.checkedURL(path: path, root: root),
                !FileManager.default.fileExists(atPath: target.path)
            else { continue }
            missing[path] = bytes
        }
        return CanvasEnsembleFileSnapshot(
            document: document,
            binding: .init(
                relativePath: relativePath, fingerprint: CanvasEnsembleFile.fingerprint(data)),
            missingEmbeddedImages: missing)
    }

    /// Saves `document` back to its bound file as `expectedRevision + 1`.
    func save(
        _ document: CanvasDocument, expectedRevision: UInt64,
        binding: CanvasEnsembleFileBinding, root: URL
    ) throws -> (document: CanvasDocument, binding: CanvasEnsembleFileBinding) {
        try document.validate()
        guard document.revision == expectedRevision, expectedRevision < UInt64.max else {
            throw CanvasError.conflict
        }
        let url = try Self.checkedFileURL(binding.relativePath, root: root)
        let current = try Self.readBytes(url)
        guard CanvasEnsembleFile.fingerprint(current) == binding.fingerprint,
            let onDisk = try? CanvasEnsembleFile.decode(current),
            onDisk.board.revision == expectedRevision
        else { throw CanvasError.conflict }
        var saved = document
        saved.revision = expectedRevision + 1
        // Keep any images the file already embeds, so a save never drops them.
        let data = try CanvasEnsembleFile(document: saved, embedded: onDisk.embeddedImages)
            .encoded()
        try Task.checkCancellation()
        try data.write(to: url, options: .atomic)
        return (
            saved,
            .init(
                relativePath: binding.relativePath,
                fingerprint: CanvasEnsembleFile.fingerprint(data))
        )
    }

    /// Writes a new file for `document` (Save As / Export). The caller already
    /// confirmed a replacement in the save panel. With `root`, the file must be
    /// inside that workspace and the result is a binding to it. Images listed
    /// in `embedImagesFrom` are read from that workspace and embedded when
    /// they fit the caps.
    func write(
        _ document: CanvasDocument, to url: URL, root: URL?, embedImagesFrom imageRoot: URL?
    ) throws -> CanvasEnsembleFileBinding? {
        var value = document
        value.revision = max(1, document.revision)
        var embedded: [String: Data] = [:]
        if let imageRoot {
            var total = 0
            for card in value.cards {
                guard case .image(let path) = card.content, embedded[path] == nil,
                    let source = try? CanvasPreviewLoader.checkedURL(path: path, root: imageRoot),
                    let bytes = try? Self.readBytes(
                        source, limit: CanvasLimits.embeddedAssetBytes),
                    total + bytes.count <= CanvasLimits.embeddedAssetsTotalBytes
                else { continue }
                total += bytes.count
                embedded[path] = bytes
            }
        }
        let data = try CanvasEnsembleFile(document: value, embedded: embedded).encoded()
        let target: URL
        var relativePath: String?
        if let root {
            let path = try Self.relativePath(forNewFile: url, root: root)
            guard path.hasSuffix("." + CanvasEnsembleFile.pathExtension) else {
                throw CanvasError.invalidPath
            }
            // The parent folder was resolved inside the workspace above; the
            // file itself may not exist yet, so it is not resolved again.
            target = url.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: url.lastPathComponent)
            relativePath = path
        } else {
            guard url.isFileURL else { throw CanvasError.invalidPath }
            target = url
        }
        try Task.checkCancellation()
        try data.write(to: target, options: .atomic)
        return relativePath.map {
            CanvasEnsembleFileBinding(
                relativePath: $0, fingerprint: CanvasEnsembleFile.fingerprint(data))
        }
    }

    /// Writes embedded images to their workspace paths. Only paths that do
    /// not exist are written; nothing is replaced. Returns the count written.
    func restore(images: [String: Data], root: URL) throws -> Int {
        var written = 0
        for (path, data) in images.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            guard CanvasEnsembleFile.mediaType(of: data) != nil,
                data.count <= CanvasLimits.embeddedAssetBytes
            else { continue }
            guard CanvasCardContent.validRelativePath(path) else { throw CanvasError.invalidPath }
            let base = root.resolvingSymlinksInPath().standardizedFileURL
            let requested = base.appending(path: path)
            // The deepest existing folder must already resolve inside the
            // workspace, so no folder is ever created through a symlink.
            var existing = requested.deletingLastPathComponent()
            while !FileManager.default.fileExists(atPath: existing.path),
                existing.path.count > base.path.count
            {
                existing = existing.deletingLastPathComponent()
            }
            let anchor = existing.resolvingSymlinksInPath().standardizedFileURL
            guard anchor.path == base.path || anchor.path.hasPrefix(base.path + "/") else {
                throw CanvasError.invalidPath
            }
            try FileManager.default.createDirectory(
                at: requested.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Resolve the (now existing) folder: a symlinked folder must not
            // move the write outside the workspace.
            let folder = requested.deletingLastPathComponent().resolvingSymlinksInPath()
                .standardizedFileURL
            guard folder.path == base.path || folder.path.hasPrefix(base.path + "/") else {
                throw CanvasError.invalidPath
            }
            let target = folder.appending(path: requested.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try data.write(to: target, options: .withoutOverwriting)
            written += 1
        }
        return written
    }

    // MARK: Helpers

    /// A workspace-relative path for a file that may not exist yet: the
    /// parent folder must resolve inside `root`.
    nonisolated static func relativePath(forNewFile url: URL, root: URL) throws -> String {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let folder = url.deletingLastPathComponent().resolvingSymlinksInPath()
            .standardizedFileURL
        let name = url.lastPathComponent
        guard url.isFileURL, !name.isEmpty else { throw CanvasError.invalidPath }
        let path: String
        if folder.path == base.path {
            path = name
        } else {
            guard folder.path.hasPrefix(base.path + "/") else { throw CanvasError.invalidPath }
            path = String(folder.path.dropFirst(base.path.count + 1)) + "/" + name
        }
        guard CanvasCardContent.validRelativePath(path) else { throw CanvasError.invalidPath }
        return path
    }

    private nonisolated static func checkedFileURL(_ path: String, root: URL) throws -> URL {
        guard path.hasSuffix("." + CanvasEnsembleFile.pathExtension) else {
            throw CanvasError.invalidPath
        }
        return try CanvasPreviewLoader.checkedURL(path: path, root: root)
    }

    /// Reads a regular file of at most `limit` bytes without following a
    /// final symlink and without blocking on a FIFO.
    private nonisolated static func readBytes(
        _ url: URL, limit: Int = CanvasLimits.ensembleFileBytes
    )
        throws -> Data
    {
        let fd = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW) } ?? -1
        }
        guard fd >= 0 else { throw CanvasError.unavailable }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= limit
        else { throw CanvasError.invalidDocument }
        var data = Data()
        while true {
            try Task.checkCancellation()
            let remaining = limit + 1 - data.count
            guard remaining > 0 else { throw CanvasError.invalidDocument }
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                !chunk.isEmpty
            else { break }
            data.append(chunk)
        }
        guard data.count <= limit else { throw CanvasError.invalidDocument }
        return data
    }
}
