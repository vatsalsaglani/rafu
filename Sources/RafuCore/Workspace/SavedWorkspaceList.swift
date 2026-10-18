import Foundation

/// One saved `.rafuworkspace` file in the "Workspaces" list.
public struct SavedWorkspaceEntry: Codable, Hashable, Identifiable, Sendable {
    /// Standardized absolute path of the `.rafuworkspace` file.
    public var filePath: String
    /// Bookmark data for the file itself, when one could be made.
    public var fileBookmark: Data?
    public var displayName: String
    /// Folder paths in workspace order (primary first), for secondary text.
    public var folderPaths: [String]
    public var lastOpened: Date

    public init(
        filePath: String, fileBookmark: Data? = nil, displayName: String,
        folderPaths: [String], lastOpened: Date
    ) {
        self.filePath = WorkspaceRootList.normalizedPath(filePath)
        self.fileBookmark = fileBookmark
        self.displayName = RafuWorkspaceFile.cleanedName(displayName)
        self.folderPaths = Array(folderPaths.prefix(WorkspaceRootList.maximumRoots))
        self.lastOpened = lastOpened
    }

    public var id: String { filePath }
}

/// The persisted "Workspaces" list: most recently opened first, bounded.
public struct SavedWorkspaceList: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let capacity = 50
    public static let maximumBytes = 1 << 20

    public var formatVersion: Int
    public private(set) var entries: [SavedWorkspaceEntry]

    public init(entries: [SavedWorkspaceEntry] = []) {
        self.formatVersion = Self.currentFormatVersion
        self.entries = Array(entries.prefix(Self.capacity))
    }

    /// Adds or refreshes `entry` and moves it to the front.
    public mutating func record(_ entry: SavedWorkspaceEntry) {
        entries.removeAll { $0.filePath == entry.filePath }
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    public mutating func remove(filePath: String) {
        let normalized = WorkspaceRootList.normalizedPath(filePath)
        entries.removeAll { $0.filePath == normalized }
    }

    /// Case- and diacritic-insensitive match on the name and every folder
    /// path. An empty query keeps every entry.
    public static func filter(
        _ entries: [SavedWorkspaceEntry], query: String
    ) -> [SavedWorkspaceEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            matches(entry.displayName, needle) || matches(entry.filePath, needle)
                || entry.folderPaths.contains { matches($0, needle) }
        }
    }

    public static func matches(_ text: String, _ needle: String) -> Bool {
        text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    /// Decodes a stored list. A newer format or damaged data gives an empty
    /// list rather than an error: the list is a convenience, never the only
    /// copy of a workspace (the `.rafuworkspace` files are).
    public static func decode(_ data: Data) -> SavedWorkspaceList {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard data.count <= maximumBytes,
            let list = try? decoder.decode(SavedWorkspaceList.self, from: data),
            list.formatVersion == currentFormatVersion
        else { return SavedWorkspaceList() }
        return SavedWorkspaceList(entries: list.entries)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        var list = self
        // Drop the oldest entries until the file fits the read bound.
        var data = try encoder.encode(list)
        while data.count > Self.maximumBytes, !list.entries.isEmpty {
            list.entries.removeLast()
            data = try encoder.encode(list)
        }
        return data
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion, entries
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        entries = try container.decode([SavedWorkspaceEntry].self, forKey: .entries)
    }
}

/// Reads and writes the saved list as one JSON file (in Application Support
/// for the app). Every write is atomic; reads are bounded. All disk access
/// runs on this actor, never on the main actor.
public actor SavedWorkspaceListStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() -> [SavedWorkspaceEntry] {
        guard let data = Self.readBounded(fileURL, limit: SavedWorkspaceList.maximumBytes) else {
            return []
        }
        return SavedWorkspaceList.decode(data).entries
    }

    @discardableResult
    public func record(_ entry: SavedWorkspaceEntry) throws -> [SavedWorkspaceEntry] {
        var list = currentList()
        list.record(entry)
        try write(list)
        return list.entries
    }

    @discardableResult
    public func remove(filePath: String) throws -> [SavedWorkspaceEntry] {
        var list = currentList()
        list.remove(filePath: filePath)
        try write(list)
        return list.entries
    }

    private func currentList() -> SavedWorkspaceList {
        SavedWorkspaceList(entries: load())
    }

    private func write(_ list: SavedWorkspaceList) throws {
        let data = try list.encoded()
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Reads at most `limit` bytes; a larger file reads as absent.
    public static func readBounded(_ url: URL, limit: Int) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else {
            return nil
        }
        return data
    }
}
