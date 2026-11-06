import CoreGraphics
import Darwin
import Foundation

/// What a batch of dropped files becomes, decided before anything changes.
/// A card never references a path outside the workspace (ADR 0025,
/// Amendment 4): a file inside the workspace is referenced in place, an
/// image from outside is copied in (with the user's consent), and any other
/// file from outside refuses the whole batch with a notice.
nonisolated struct CanvasAssetImportPlan: Equatable, Sendable {
    enum Item: Equatable, Sendable {
        /// A regular file inside the workspace, by its relative path.
        case inside(String)
        /// A raster image outside the workspace (symlinks resolved), to copy.
        case externalImage(URL)
    }

    /// The accepted files, in drop order. Folders inside the workspace are
    /// left out, as before.
    var items: [Item] = []
    /// Files from outside the workspace that cannot be copied in: anything
    /// that is not a raster image, and folders.
    var refused: [URL] = []

    var externalImages: [URL] {
        items.compactMap { if case .externalImage(let url) = $0 { url } else { nil } }
    }

    var insidePaths: [String] {
        items.compactMap { if case .inside(let path) = $0 { path } else { nil } }
    }

    /// Classifies `urls` against `root`. Reads file metadata only, never file
    /// contents, so call it off the main actor. Throws `invalidPath` for a
    /// non-file URL or for something inside the workspace that is not a
    /// regular file, as the drop did before.
    static func resolve(urls: [URL], root: URL) throws -> Self {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        var plan = Self()
        for url in urls {
            guard url.isFileURL else { throw CanvasError.invalidPath }
            let target = url.resolvingSymlinksInPath().standardizedFileURL
            let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if let path = insideRelativePath(target, base: base) {
                // A folder from the Files list or Finder is ignored, not an
                // error: the rest of the batch still lands.
                if values?.isDirectory == true { continue }
                guard values?.isRegularFile == true else { throw CanvasError.invalidPath }
                plan.items.append(.inside(path))
            } else if values?.isRegularFile == true, CanvasDroppedFileKind.isImage(target) {
                plan.items.append(.externalImage(target))
            } else {
                plan.refused.append(url)
            }
        }
        return plan
    }

    /// The workspace-relative path of `target` (already resolved), or `nil`
    /// when it is not strictly inside `base`.
    static func insideRelativePath(_ target: URL, base: URL) -> String? {
        guard target.path.hasPrefix(base.path + "/") else { return nil }
        let path = String(target.path.dropFirst(base.path.count + 1))
        guard (try? CanvasPreviewLoader.checkedURL(path: path, root: base)) != nil else {
            return nil
        }
        return path
    }

    /// The notice for a refused batch, naming one file when there is one.
    static func refusalMessage(for refused: [URL]) -> String {
        if refused.count == 1, let url = refused.first {
            return
                "\u{201C}\(url.lastPathComponent)\u{201D} is outside this workspace. Only images from outside can be copied in."
        }
        return
            "\(refused.count) items are outside this workspace. Only images from outside can be copied in."
    }
}

/// External images that wait for the user's "Copy" before anything is
/// written. Held on the board (`CanvasBoardState.pendingAssetImport`).
nonisolated struct CanvasAssetImportRequest: Identifiable, Equatable, Sendable {
    let id = UUID()
    let boardID: CanvasID
    let plan: CanvasAssetImportPlan
    /// Where the drop happened, in the board view's top-left space.
    let location: CGPoint
    /// The workspace-relative folder the images go to.
    let folder: String

    var imageCount: Int { plan.externalImages.count }

    /// "Copy 11 images into .rafu/ensemble-assets/plan?"
    var title: String {
        let noun = imageCount == 1 ? "1 image" : "\(imageCount) images"
        return "Copy \(noun) into \(folder)?"
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

/// Copies external images into the workspace. Every write is bounded,
/// atomic (a temporary file, then an exclusive rename), never overwrites,
/// never follows a symlink, and never creates a folder through a symlink
/// that leaves the workspace.
nonisolated enum CanvasAssetImporter {
    /// The default parent folder, relative to the workspace root. The board
    /// slug is added below it.
    static let defaultFolder = ".rafu/ensemble-assets"
    /// The largest image Rafu copies, the same cap the image card decodes.
    static let maxFileBytes = 16 * 1_024 * 1_024

    enum ImportError: LocalizedError, Equatable {
        case tooLarge(String)
        case unreadable(String)
        case folderOutsideWorkspace

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name):
                "\u{201C}\(name)\u{201D} is larger than 16 MB. Rafu copied no images."
            case .unreadable(let name):
                "Rafu could not read \u{201C}\(name)\u{201D}. Rafu copied no images."
            case .folderOutsideWorkspace:
                "The image folder is not inside this workspace. Rafu copied no images."
            }
        }
    }

    /// `parent/<board slug>`. An invalid `parent` falls back to the default.
    static func folder(parent: String?, boardTitle: String) -> String {
        let trimmed = parent?.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let base =
            trimmed.flatMap { CanvasCardContent.validRelativePath($0) ? $0 : nil }
            ?? defaultFolder
        return base + "/" + slug(boardTitle)
    }

    /// A lowercase, file-name-safe form of a board title: letters, digits
    /// and single hyphens, at most 60 characters, "ensemble" when empty.
    static func slug(_ title: String) -> String {
        var result = ""
        var lastWasHyphen = true
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
                result.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
            if result.count >= 60 { break }
        }
        while result.hasSuffix("-") { result.removeLast() }
        return result.isEmpty ? "ensemble" : result
    }

    /// `name`, else `stem-2.ext`, `stem-3.ext`, … — the first that `isTaken`
    /// does not report.
    static func uniqueName(for name: String, isTaken: (String) -> Bool) -> String {
        guard isTaken(name) else { return name }
        let ext = (name as NSString).pathExtension
        let stem = (name as NSString).deletingPathExtension
        var index = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(index)" : "\(stem)-\(index).\(ext)"
            if !isTaken(candidate) { return candidate }
            index += 1
        }
    }

    /// Copies `sources` into `folder` (relative to `root`) and returns the
    /// new relative paths in the same order. All or nothing: on any failure
    /// the files this call already wrote are removed again.
    @concurrent
    static func copy(_ sources: [URL], into folder: String, root: URL) async throws -> [String] {
        try copySynchronously(sources, into: folder, root: root)
    }

    /// Removes files that `copy` wrote, by the relative paths it returned,
    /// when the board then refuses their cards (for example an agent filled
    /// the board during the copy). Paths that are not valid workspace-relative
    /// paths are skipped.
    @concurrent
    static func removeCopies(_ relativePaths: [String], root: URL) async {
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        for path in relativePaths where CanvasCardContent.validRelativePath(path) {
            try? FileManager.default.removeItem(at: base.appending(path: path))
        }
    }

    static func copySynchronously(_ sources: [URL], into folder: String, root: URL) throws
        -> [String]
    {
        guard CanvasCardContent.validRelativePath(folder) else {
            throw ImportError.folderOutsideWorkspace
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let directory = try preparedFolder(folder, base: base)
        let relativeFolder = String(directory.path.dropFirst(base.path.count + 1))
        var written: [URL] = []
        do {
            var paths: [String] = []
            for source in sources {
                try Task.checkCancellation()
                let data = try boundedRead(source)
                let name = try write(data, named: source.lastPathComponent, in: directory)
                written.append(directory.appending(path: name))
                paths.append(relativeFolder + "/" + name)
            }
            return paths
        } catch {
            for url in written { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Creates `folder` under `base` and returns it resolved. The deepest
    /// folder that already exists must resolve inside the workspace, so no
    /// folder is created through a symlink that points elsewhere.
    private static func preparedFolder(_ folder: String, base: URL) throws -> URL {
        let requested = base.appending(path: folder)
        var existing = requested
        while !FileManager.default.fileExists(atPath: existing.path),
            existing.path.count > base.path.count
        {
            existing = existing.deletingLastPathComponent()
        }
        guard isInside(existing.resolvingSymlinksInPath().standardizedFileURL, base: base) else {
            throw ImportError.folderOutsideWorkspace
        }
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let resolved = requested.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base.path + "/") else {
            throw ImportError.folderOutsideWorkspace
        }
        return resolved
    }

    private static func isInside(_ url: URL, base: URL) -> Bool {
        url.path == base.path || url.path.hasPrefix(base.path + "/")
    }

    /// The whole file, at most `maxFileBytes`. Refuses a symlink, a
    /// non-regular file, and an oversized file before reading any bytes.
    static func boundedRead(_ url: URL) throws -> Data {
        let name = url.lastPathComponent
        let descriptor = url.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else { throw ImportError.unreadable(name) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ImportError.unreadable(name)
        }
        guard info.st_size <= maxFileBytes else { throw ImportError.tooLarge(name) }
        let data = try handle.read(upToCount: maxFileBytes + 1) ?? Data()
        guard data.count <= maxFileBytes else { throw ImportError.tooLarge(name) }
        return data
    }

    /// Writes `data` to a new temporary file in `directory`, then renames it
    /// to the first free name with `RENAME_EXCL`, so an existing file is
    /// never replaced and a reader never sees a partial image.
    private static func write(_ data: Data, named name: String, in directory: URL) throws
        -> String
    {
        let temporary = directory.appending(path: ".rafu-import-\(UUID().uuidString)")
        let descriptor = temporary.withUnsafeFileSystemRepresentation { path in
            path.map {
                Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
            } ?? -1
        }
        guard descriptor >= 0 else { throw ImportError.unreadable(name) }
        do {
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            unlink(temporary.path)
            throw error
        }
        var taken: Set<String> = []
        for _ in 0..<1_000 {
            let candidate = uniqueName(for: name) { candidate in
                taken.contains(candidate)
                    || FileManager.default.fileExists(
                        atPath: directory.appending(path: candidate).path)
            }
            // `errno` is read inside the closure, right after the call.
            let failure = temporary.withUnsafeFileSystemRepresentation { from in
                directory.appending(path: candidate).withUnsafeFileSystemRepresentation { to in
                    guard let from, let to else { return EINVAL }
                    return renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 ? 0 : errno
                }
            }
            if failure == 0 { return candidate }
            guard failure == EEXIST else { break }
            taken.insert(candidate)
        }
        unlink(temporary.path)
        throw ImportError.unreadable(name)
    }
}

/// The per-workspace choices for copying external images: "always copy
/// without asking" and the parent folder (`ensembleAssetFolder`). A small
/// JSON blob in `UserDefaults`, keyed by the workspace root path, like
/// `WorkspaceSearchHistoryStore`. It holds no file contents.
nonisolated struct CanvasAssetImportPreferences: Sendable {
    private static let defaultsKey = "dev.rafu.ensemble-asset-import.v1"

    struct Entry: Codable, Equatable, Sendable {
        var alwaysCopy = false
        var ensembleAssetFolder: String?
    }

    /// `nil` uses the standard defaults; tests pass a suite they remove.
    private let suiteName: String?

    init(suiteName: String? = nil) {
        self.suiteName = suiteName
    }

    private var defaults: UserDefaults {
        suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
    }

    func entry(forRootPath rootPath: String) -> Entry {
        loadAll()[rootPath] ?? Entry()
    }

    func setAlwaysCopy(_ value: Bool, forRootPath rootPath: String) {
        var all = loadAll()
        var entry = all[rootPath] ?? Entry()
        entry.alwaysCopy = value
        all[rootPath] = entry
        save(all)
    }

    private func loadAll() -> [String: Entry] {
        guard let data = defaults.data(forKey: Self.defaultsKey),
            let entries = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return entries
    }

    private func save(_ entries: [String: Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}
