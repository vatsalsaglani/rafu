import CryptoKit
import Darwin
import Foundation

/// Why a model folder is refused. Each case names a relative path inside the
/// folder (a catalog path, never a user value).
public enum MeetingModelVerificationError: Error, Hashable, Sendable {
    /// A catalog path or a path in the folder is not a plain relative path
    /// (it is empty, absolute, or has `..`, `.` or an empty part).
    case unsafePath(String)
    /// The folder holds a symbolic link (or the folder itself is one).
    case symbolicLink(String)
    /// The folder holds something that is not a regular file or a folder.
    case notRegularFile(String)
    /// A catalog file is not in the folder.
    case missingFile(String)
    /// The folder holds a file that is not in the catalog.
    case unexpectedFile(String)
    /// A file has a different size than the catalog.
    case wrongSize(String, expected: Int64, actual: Int64)
    /// A file has a different SHA-256 than the catalog.
    case checksumMismatch(String)
    /// A file could not be read.
    case unreadable(String)
    /// Two catalog files have the same local path.
    case duplicatePath(String)

    /// The diagnostics value of this refusal.
    public var checksumResult: MeetingChecksumResult {
        switch self {
        case .wrongSize: .wrongSize
        case .missingFile: .missingFile
        case .unsafePath, .symbolicLink, .notRegularFile, .unexpectedFile, .checksumMismatch,
            .unreadable, .duplicatePath:
            .mismatched
        }
    }
}

/// Checks a model folder against the catalog: path rules, exact sizes and
/// SHA-256 (streamed). It reads files only; it never changes the folder.
public enum MeetingModelVerifier {
    /// The files that Rafu itself writes into an installed folder. They are
    /// allowed at the top level and are not checked.
    public static let rafuFileNames: Set<String> = [
        MeetingModelInstallFiles.licenseFileName,
        MeetingModelInstallFiles.noticeFileName,
        MeetingModelInstallFiles.verifiedMarkerFileName,
    ]

    /// The size of one read when hashing.
    static let readBlockBytes = 1 << 20

    /// True for a plain relative path: not empty, not absolute, no `\`, and no
    /// empty, `.` or `..` part.
    public static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
            !path.contains("\0")
        else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Checks the catalog paths of `entry` only (no file access).
    public static func checkCatalogPaths(
        _ entry: MeetingModelCatalogEntry
    ) throws(MeetingModelVerificationError) {
        var seen: Set<String> = []
        for file in entry.files {
            guard isSafeRelativePath(file.localPath) else {
                throw .unsafePath(file.localPath)
            }
            guard isSafeRelativePath(file.remotePath) else {
                throw .unsafePath(file.remotePath)
            }
            guard seen.insert(file.localPath).inserted else {
                throw .duplicatePath(file.localPath)
            }
        }
    }

    /// Checks that `folder` holds exactly the files of `entry` (plus the Rafu
    /// files, when `allowRafuFiles`), with no symbolic link, each with the
    /// exact size and SHA-256. Sizes and the tree are checked before any hash,
    /// so a wrong tree fails fast.
    public static func verify(
        folder: URL, entry: MeetingModelCatalogEntry, allowRafuFiles: Bool = true
    ) throws(MeetingModelVerificationError) {
        try checkCatalogPaths(entry)
        let expected = Dictionary(
            uniqueKeysWithValues: entry.files.map { ($0.localPath, $0) })
        let found = try regularFiles(in: folder)

        for path in found.keys.sorted() where expected[path] == nil {
            if allowRafuFiles, rafuFileNames.contains(path) { continue }
            throw .unexpectedFile(path)
        }
        for file in entry.files {
            guard let size = found[file.localPath] else { throw .missingFile(file.localPath) }
            guard size == file.bytes else {
                throw .wrongSize(file.localPath, expected: file.bytes, actual: size)
            }
        }
        for file in entry.files {
            let url = folder.appending(path: file.localPath, directoryHint: .notDirectory)
            let digest = try sha256(of: url, path: file.localPath, limit: file.bytes)
            guard digest == file.sha256.lowercased() else {
                throw .checksumMismatch(file.localPath)
            }
        }
    }

    /// Lists each regular file below `folder` by relative path, with its size.
    /// Refuses a symbolic link anywhere (also the folder itself) and any other
    /// non-regular item.
    static func regularFiles(
        in folder: URL
    ) throws(MeetingModelVerificationError) -> [String: Int64] {
        let root = folder.path(percentEncoded: false)
        switch itemKind(atPath: root) {
        case .directory: break
        case .symbolicLink: throw .symbolicLink(".")
        case .missing: throw .missingFile(".")
        case .file, .other: throw .notRegularFile(".")
        }
        guard let enumerator = FileManager.default.enumerator(atPath: root) else {
            throw .unreadable(".")
        }
        var result: [String: Int64] = [:]
        while let relative = enumerator.nextObject() as? String {
            guard isSafeRelativePath(relative) else { throw .unsafePath(relative) }
            let full = (root as NSString).appendingPathComponent(relative)
            switch itemKind(atPath: full) {
            case .directory: continue
            case .file(let size): result[relative] = size
            case .symbolicLink: throw .symbolicLink(relative)
            case .missing: throw .unreadable(relative)
            case .other: throw .notRegularFile(relative)
            }
        }
        return result
    }

    enum ItemKind: Equatable {
        case directory
        case file(Int64)
        case symbolicLink
        case other
        case missing
    }

    /// `lstat`, so a symbolic link is seen as a link and never followed.
    static func itemKind(atPath path: String) -> ItemKind {
        var info = stat()
        guard lstat(path, &info) == 0 else { return .missing }
        switch info.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file(Int64(info.st_size))
        case S_IFLNK: return .symbolicLink
        default: return .other
        }
    }

    /// The streamed SHA-256 of a file, lowercase hexadecimal. Reads at most
    /// `limit + 1` bytes (a larger file is already refused by size). Opens with
    /// `O_NOFOLLOW`, so a link swapped in after the tree check is refused.
    static func sha256(
        of url: URL, path: String, limit: Int64
    ) throws(MeetingModelVerificationError) -> String {
        let descriptor = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw .unreadable(path) }
        defer { close(descriptor) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: readBlockBytes)
        var total: Int64 = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(descriptor, raw.baseAddress, raw.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw .unreadable(path)
            }
            if count == 0 { break }
            total += Int64(count)
            guard total <= limit else {
                throw .wrongSize(path, expected: limit, actual: total)
            }
            buffer.withUnsafeBytes { raw in
                hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: raw[0..<count]))
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// The names and texts of the files that Rafu writes into an installed model
/// folder. Pure: the installer writes what these return.
public enum MeetingModelInstallFiles {
    public static let licenseFileName = "LICENSE.txt"
    public static let noticeFileName = "NOTICE"
    /// Written last, after each file is checked. `installedFolder(for:)`
    /// returns a folder only when this file holds the pinned revision.
    public static let verifiedMarkerFileName = ".rafu-verified"
    /// The staging folder below the models root. A download lands here first.
    public static let stagingFolderName = ".staging"

    /// `<models root>/<model id>/<revision>/`.
    public static func installFolder(modelsRoot: URL, entry: MeetingModelCatalogEntry) -> URL {
        modelsRoot
            .appending(path: entry.id.rawValue, directoryHint: .isDirectory)
            .appending(path: entry.revision, directoryHint: .isDirectory)
    }

    /// The licence file: the licence name, where its text is published, and
    /// where the model came from.
    public static func licenseText(for entry: MeetingModelCatalogEntry) -> String {
        var lines = [
            "\(entry.displayName)",
            "",
            "Licence: \(entry.licenseName)",
            "Licence text: \(entry.licenseURL)",
            "",
            "Downloaded by Rafu from Hugging Face at pinned revisions:",
        ]
        let sources = Set(entry.files.map { "\($0.repository) @ \($0.revision)" })
        lines.append(contentsOf: sources.sorted().map { "- \($0)" })
        return lines.joined(separator: "\n") + "\n"
    }

    /// The `NOTICE` file: the attribution line.
    public static func noticeText(for entry: MeetingModelCatalogEntry) -> String {
        entry.attribution + "\n"
    }

    /// The marker text: the pinned revision and one line end.
    public static func markerText(for entry: MeetingModelCatalogEntry) -> String {
        entry.revision + "\n"
    }

    /// True when `folder` is a real folder (not a symbolic link) whose marker
    /// is a regular file that holds the pinned revision of `entry`. It does
    /// not hash the files again: the installer wrote the marker only after
    /// each file passed the check.
    public static func isVerifiedInstall(folder: URL, entry: MeetingModelCatalogEntry) -> Bool {
        guard
            MeetingModelVerifier.itemKind(atPath: folder.path(percentEncoded: false)) == .directory
        else { return false }
        let marker = folder.appending(path: verifiedMarkerFileName, directoryHint: .notDirectory)
        guard
            case .file(let size) = MeetingModelVerifier.itemKind(
                atPath: marker.path(percentEncoded: false)),
            size < 256,
            let data = FileManager.default.contents(atPath: marker.path(percentEncoded: false))
        else { return false }
        return String(decoding: data, as: UTF8.self) == markerText(for: entry)
    }
}
