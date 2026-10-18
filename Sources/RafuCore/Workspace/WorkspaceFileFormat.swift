import Foundation

/// A saved multi-folder workspace: the `.rafuworkspace` file.
///
/// Versioned JSON (UTType `dev.rafu.workspace`, conforms to `public.json`).
/// Each folder keeps bookmark data and its last known path, so the file
/// still opens when a bookmark cannot be resolved (another Mac, a moved
/// volume). The file holds no document text, no terminal state, and no
/// secrets.
public struct RafuWorkspaceFile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let pathExtension = "rafuworkspace"
    public static let typeIdentifier = "dev.rafu.workspace"
    /// Reads refuse larger files before they are parsed.
    public static let maximumBytes = 1 << 20
    public static let maximumNameLength = 200
    /// Bookmark data is a few KiB; anything far larger is not a bookmark.
    public static let maximumBookmarkBytes = 64 * 1_024

    public struct Folder: Codable, Equatable, Sendable {
        /// Bookmark data for the folder (security-scoped when the system
        /// allows it). Optional: a file written by hand may leave it out.
        public var bookmark: Data?
        /// Absolute path when the file was saved.
        public var lastKnownPath: String

        public init(bookmark: Data?, lastKnownPath: String) {
            self.bookmark = bookmark
            self.lastKnownPath = lastKnownPath
        }
    }

    public var formatVersion: Int
    public var displayName: String
    public var folders: [Folder]
    /// Index into `folders` of the primary folder. `nil` means the first.
    public var primaryIndex: Int?
    /// Reserved for a later window layout reference. Rafu 1 writes `nil` and
    /// ignores any value it reads.
    public var layoutReference: String?

    public init(
        displayName: String, folders: [Folder], primaryIndex: Int? = nil,
        layoutReference: String? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.displayName = displayName
        self.folders = folders
        self.primaryIndex = primaryIndex
        self.layoutReference = layoutReference
    }

    /// Folders with the primary one first.
    public var orderedFolders: [Folder] {
        WorkspaceRootList.reordered(folders, primaryIndex: primaryIndex)
    }

    // MARK: - Coding

    private struct VersionProbe: Decodable {
        let formatVersion: Int?
    }

    /// Decodes and validates bytes read from disk. Refuses files over
    /// `maximumBytes`, unknown future versions, and malformed content.
    public static func decode(_ data: Data) throws -> RafuWorkspaceFile {
        guard data.count <= maximumBytes else {
            throw RafuWorkspaceFileError.tooLarge(byteCount: data.count)
        }
        let decoder = JSONDecoder()
        let probe: VersionProbe
        do {
            probe = try decoder.decode(VersionProbe.self, from: data)
        } catch {
            throw RafuWorkspaceFileError.malformed("The file is not valid workspace JSON.")
        }
        guard let version = probe.formatVersion else {
            throw RafuWorkspaceFileError.malformed("The file has no format version.")
        }
        guard version <= currentFormatVersion else {
            throw RafuWorkspaceFileError.unsupportedVersion(version)
        }
        guard version >= 1 else {
            throw RafuWorkspaceFileError.malformed("The format version \(version) is not valid.")
        }
        let file: RafuWorkspaceFile
        do {
            file = try decoder.decode(RafuWorkspaceFile.self, from: data)
        } catch {
            throw RafuWorkspaceFileError.malformed("A required field is missing or has a bad type.")
        }
        return try file.validated()
    }

    /// Encodes as stable, readable JSON (sorted keys).
    public func encoded() throws -> Data {
        let checked = try validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(checked)
        guard data.count <= Self.maximumBytes else {
            throw RafuWorkspaceFileError.tooLarge(byteCount: data.count)
        }
        return data
    }

    /// Checks the rules every reader and writer relies on. A bad
    /// `primaryIndex` is dropped (the first folder becomes primary) instead
    /// of refusing the whole file; the layout reference is not used yet.
    public func validated() throws -> RafuWorkspaceFile {
        guard !folders.isEmpty else { throw RafuWorkspaceFileError.noFolders }
        guard folders.count <= WorkspaceRootList.maximumRoots else {
            throw RafuWorkspaceFileError.tooManyFolders(folders.count)
        }
        var result = self
        result.formatVersion = Self.currentFormatVersion
        result.displayName = Self.cleanedName(displayName)
        for folder in folders {
            guard folder.lastKnownPath.hasPrefix("/"),
                !folder.lastKnownPath.contains("\u{0}"),
                folder.lastKnownPath.utf8.count <= 4_096
            else {
                throw RafuWorkspaceFileError.malformed("A folder path is not an absolute path.")
            }
            if let bookmark = folder.bookmark, bookmark.count > Self.maximumBookmarkBytes {
                throw RafuWorkspaceFileError.malformed("A folder bookmark is too large.")
            }
        }
        if let index = primaryIndex, !folders.indices.contains(index) {
            result.primaryIndex = nil
        }
        if let reference = layoutReference, reference.utf8.count > 1_024 {
            result.layoutReference = nil
        }
        return result
    }

    /// A one-line display name of bounded length; never empty.
    public static func cleanedName(_ name: String) -> String {
        let oneLine = name.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return "Workspace" }
        return String(oneLine.prefix(maximumNameLength))
    }

    /// The display name a new file gets from its file name
    /// (`Project.rafuworkspace` gives `Project`).
    public static func displayName(forFileName fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        return cleanedName(base)
    }
}

public enum RafuWorkspaceFileError: LocalizedError, Equatable, Sendable {
    case tooLarge(byteCount: Int)
    case unsupportedVersion(Int)
    case malformed(String)
    case noFolders
    case tooManyFolders(Int)
    case noFolderAvailable

    public var errorDescription: String? {
        switch self {
        case .tooLarge(let byteCount):
            "The workspace file is too large (\(byteCount) bytes). The limit is 1 MiB."
        case .unsupportedVersion(let version):
            "This workspace file uses format \(version), which is newer than this version of "
                + "Rafu can read (format \(RafuWorkspaceFile.currentFormatVersion)). "
                + "Update Rafu to open it."
        case .malformed(let reason):
            "The workspace file is damaged. \(reason)"
        case .noFolders:
            "The workspace file has no folders."
        case .tooManyFolders(let count):
            "The workspace file has \(count) folders. The limit is "
                + "\(WorkspaceRootList.maximumRoots)."
        case .noFolderAvailable:
            "None of the folders in this workspace could be found."
        }
    }
}
