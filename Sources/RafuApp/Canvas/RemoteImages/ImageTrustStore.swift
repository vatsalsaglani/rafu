import Foundation

/// One saved trust-list entry.
nonisolated struct ImageTrustEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Source: String, Codable, Sendable {
        /// Added from the consent card.
        case confirm
        /// Added by typing in Settings.
        case settings
    }

    var pattern: String
    var addedAt: Date
    var source: Source

    var id: String { pattern }
}

/// What a load found.
nonisolated struct ImageTrustLoadReport: Equatable, Sendable {
    var entries: [ImageTrustEntry]
    /// Entries that were not valid, duplicates, or over the cap.
    var skipped: Int
    /// The file could not be read as JSON. It was renamed, not deleted.
    var fileWasUnreadable: Bool
}

nonisolated enum ImageTrustStoreError: Error, Equatable, Sendable {
    case full
    case writeFailed
}

/// The image host trust list on disk: `image-trust.json` in Rafu's
/// Application Support folder. Not part of any Ensemble file and not
/// reachable by any agent tool.
///
/// The file is written atomically with mode 0600 and holds at most
/// `maxEntries` entries. A file that cannot be read is renamed to
/// `image-trust.invalid.json` (never deleted or overwritten in place).
actor ImageTrustStore {
    static let maxEntries = 200
    static let maxFileBytes = 256 * 1_024
    static let invalidFileName = "image-trust.invalid.json"
    private static let maxUndo = 20

    private nonisolated struct FileContents: Codable {
        var version = 1
        var entries: [ImageTrustEntry]
    }

    let fileURL: URL
    private(set) var entries: [ImageTrustEntry] = []
    private var undoStack: [[ImageTrustEntry]] = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    var canUndo: Bool { !undoStack.isEmpty }

    // MARK: Load

    /// Reads the file. A missing file is an empty list. Invalid entries are
    /// skipped and counted.
    func load(suffixes: any PublicSuffixProviding) -> ImageTrustLoadReport {
        undoStack.removeAll()
        let data: Data
        do {
            guard let read = try readBounded() else {
                entries = []
                return ImageTrustLoadReport(entries: [], skipped: 0, fileWasUnreadable: false)
            }
            data = read
        } catch {
            entries = []
            quarantine()
            return ImageTrustLoadReport(entries: [], skipped: 0, fileWasUnreadable: true)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Decode entries one by one, so one bad entry skips only itself.
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["version"] as? Int == 1,
            let rawEntries = object["entries"] as? [Any]
        else {
            entries = []
            quarantine()
            return ImageTrustLoadReport(entries: [], skipped: 0, fileWasUnreadable: true)
        }
        var accepted: [ImageTrustEntry] = []
        var seen = Set<String>()
        var skipped = 0
        for raw in rawEntries {
            guard accepted.count < Self.maxEntries,
                JSONSerialization.isValidJSONObject(raw),
                let itemData = try? JSONSerialization.data(withJSONObject: raw),
                var entry = try? decoder.decode(ImageTrustEntry.self, from: itemData),
                let pattern = try? HostPattern.parse(entry.pattern, suffixes: suffixes),
                seen.insert(pattern.text).inserted
            else {
                skipped += 1
                continue
            }
            entry.pattern = pattern.text
            accepted.append(entry)
        }
        entries = accepted
        return ImageTrustLoadReport(entries: accepted, skipped: skipped, fileWasUnreadable: false)
    }

    private func readBounded() throws -> Data? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maxFileBytes + 1) ?? Data()
        if data.count > Self.maxFileBytes { throw ImageTrustStoreError.writeFailed }
        return data
    }

    private func quarantine() {
        let destination = fileURL.deletingLastPathComponent()
            .appending(path: Self.invalidFileName, directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }

    // MARK: Edit

    /// Adds `pattern`. Adding one that is already there changes nothing.
    @discardableResult
    func add(
        _ pattern: HostPattern, source: ImageTrustEntry.Source, now: Date = Date()
    ) throws(ImageTrustStoreError) -> [ImageTrustEntry] {
        guard !entries.contains(where: { $0.pattern == pattern.text }) else { return entries }
        guard entries.count < Self.maxEntries else { throw .full }
        var next = entries
        next.append(ImageTrustEntry(pattern: pattern.text, addedAt: now, source: source))
        try commit(next)
        return entries
    }

    @discardableResult
    func remove(pattern: String) throws(ImageTrustStoreError) -> [ImageTrustEntry] {
        let next = entries.filter { $0.pattern != pattern }
        guard next.count != entries.count else { return entries }
        try commit(next)
        return entries
    }

    @discardableResult
    func removeAll() throws(ImageTrustStoreError) -> [ImageTrustEntry] {
        guard !entries.isEmpty else { return entries }
        try commit([])
        return entries
    }

    /// Puts the list back as it was before the last change in this session.
    @discardableResult
    func undoLast() throws(ImageTrustStoreError) -> [ImageTrustEntry] {
        guard let previous = undoStack.last else { return entries }
        try write(previous)
        undoStack.removeLast()
        entries = previous
        return entries
    }

    private func commit(_ next: [ImageTrustEntry]) throws(ImageTrustStoreError) {
        try write(next)
        undoStack.append(entries)
        if undoStack.count > Self.maxUndo { undoStack.removeFirst() }
        entries = next
    }

    // MARK: Write

    private func write(_ list: [ImageTrustEntry]) throws(ImageTrustStoreError) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(FileContents(entries: list)) else {
            throw .writeFailed
        }
        let directory = fileURL.deletingLastPathComponent()
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            // The temporary file is created 0600, then renamed over the real one,
            // so the list is never visible half-written or world-readable.
            let temporary = directory.appending(
                path: ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
                directoryHint: .notDirectory)
            guard
                fileManager.createFile(
                    atPath: temporary.path, contents: data,
                    attributes: [.posixPermissions: 0o600])
            else { throw ImageTrustStoreError.writeFailed }
            if Darwin.rename(temporary.path, fileURL.path) != 0 {
                try? fileManager.removeItem(at: temporary)
                throw ImageTrustStoreError.writeFailed
            }
        } catch {
            throw .writeFailed
        }
    }
}
