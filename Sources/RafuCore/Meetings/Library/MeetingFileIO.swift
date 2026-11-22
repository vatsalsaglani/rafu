import Darwin
import Foundation

/// Small file helpers for the meeting library: private modes, bounded reads
/// that never follow a symbolic link, atomic replace and `fsync`ed append.
/// File and folder names stay below the injected library root.
enum MeetingFileIO {
    static let directoryMode: mode_t = 0o700
    static let fileMode: mode_t = 0o600

    /// The size limit of one line of a `.jsonl` file. A longer line is
    /// skipped and counted when read, and refused when written.
    static let maximumLineBytes = 64 * 1024

    // MARK: Paths

    /// The path for a system call. `URL.path(percentEncoded:)` keeps the
    /// trailing slash of a folder URL, and `lstat` follows a symbolic link
    /// when the path ends in a slash, so the slash is removed here.
    static func posixPath(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    // MARK: Folders

    /// Makes a folder and each missing parent with mode 0700. A folder that
    /// exists as a symbolic link or a file is refused.
    static func ensurePrivateDirectory(_ url: URL) throws {
        let path = posixPath(url)
        var info = stat()
        if lstat(path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFDIR: return
            case S_IFLNK: throw MeetingStoreError.symbolicLinkRefused
            default: throw MeetingStoreError.notARegularFile
            }
        }
        guard errno == ENOENT else { throw MeetingStoreError.io(code: errno) }
        let parent = url.deletingLastPathComponent()
        if posixPath(parent) != path {
            try ensurePrivateDirectory(parent)
        }
        if mkdir(path, directoryMode) != 0, errno != EEXIST {
            throw MeetingStoreError.io(code: errno)
        }
        _ = chmod(path, directoryMode)
    }

    /// The `lstat` result for a path, or nil when nothing is there.
    static func lstatInfo(_ url: URL) -> stat? {
        var info = stat()
        guard lstat(posixPath(url), &info) == 0 else { return nil }
        return info
    }

    /// True when the path is a real folder (not a symbolic link).
    static func isRealDirectory(_ url: URL) -> Bool {
        guard let info = lstatInfo(url) else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    // MARK: Read

    /// Reads a whole regular file. Returns nil when the file is missing.
    /// Throws for a symbolic link, a file that is not regular or a file over
    /// `maximumBytes`.
    static func readBounded(_ url: URL, maximumBytes: Int) throws -> Data? {
        let path = posixPath(url)
        var info = stat()
        if lstat(path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw MeetingStoreError.io(code: errno)
        }
        switch info.st_mode & S_IFMT {
        case S_IFREG: break
        case S_IFLNK: throw MeetingStoreError.symbolicLinkRefused
        default: throw MeetingStoreError.notARegularFile
        }
        if info.st_size > maximumBytes {
            throw MeetingStoreError.fileTooLarge(limit: maximumBytes)
        }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw MeetingStoreError.symbolicLinkRefused }
            throw MeetingStoreError.io(code: errno)
        }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG else {
            throw MeetingStoreError.notARegularFile
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw MeetingStoreError.io(code: errno)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > maximumBytes {
                throw MeetingStoreError.fileTooLarge(limit: maximumBytes)
            }
        }
        return data
    }

    /// The lines of a `.jsonl` file. An empty line is ignored. A line longer
    /// than `maximumLineBytes` is skipped and counted.
    static func lines(of data: Data) -> (lines: [Data], skipped: Int) {
        var result: [Data] = []
        var skipped = 0
        for piece in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if piece.count > maximumLineBytes {
                skipped += 1
            } else {
                result.append(Data(piece))
            }
        }
        return (result, skipped)
    }

    // MARK: Write

    /// Writes `data` to a temporary file next to `url`, syncs it and renames
    /// it over `url`. A failure before the rename leaves the old file as it
    /// was and removes the temporary file. `beforeRename` is for tests.
    static func atomicWrite(
        _ data: Data, to url: URL, beforeRename: (() throws -> Void)? = nil
    ) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appending(
            path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp",
            directoryHint: .notDirectory)
        let temporaryPath = posixPath(temporary)
        let descriptor = open(
            temporaryPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else { throw MeetingStoreError.io(code: errno) }
        var finished = false
        defer {
            if !finished { unlink(temporaryPath) }
        }
        do {
            try writeAll(data, to: descriptor)
            guard fsync(descriptor) == 0 else { throw MeetingStoreError.io(code: errno) }
            close(descriptor)
        } catch {
            close(descriptor)
            throw error
        }
        try beforeRename?()
        guard rename(temporaryPath, posixPath(url)) == 0 else {
            throw MeetingStoreError.io(code: errno)
        }
        finished = true
    }

    /// Appends `data` to a file (made with mode 0600 when missing) and syncs.
    /// A file that ends in a partial line gets a newline first, so a crash in
    /// the middle of a line never joins two records.
    static func append(_ data: Data, to url: URL) throws {
        let path = posixPath(url)
        let descriptor = open(
            path, O_RDWR | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, fileMode)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw MeetingStoreError.symbolicLinkRefused }
            throw MeetingStoreError.io(code: errno)
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw MeetingStoreError.notARegularFile
        }
        var payload = Data()
        if info.st_size > 0 {
            var last: UInt8 = 0
            if pread(descriptor, &last, 1, info.st_size - 1) == 1, last != 0x0A {
                payload.append(0x0A)
            }
        }
        payload.append(data)
        try writeAll(payload, to: descriptor)
        guard fsync(descriptor) == 0 else { throw MeetingStoreError.io(code: errno) }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(descriptor, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw MeetingStoreError.io(code: errno)
                }
                offset += written
            }
        }
    }

    // MARK: Sizes and removal

    /// The size of a regular file, or 0 for a missing file, a symbolic link
    /// or anything that is not a regular file.
    static func regularFileSize(_ url: URL) -> Int64 {
        guard let info = lstatInfo(url), (info.st_mode & S_IFMT) == S_IFREG else { return 0 }
        return Int64(info.st_size)
    }

    /// The regular files directly in a folder, never following a link.
    static func regularFiles(in directory: URL) -> [(url: URL, size: Int64, modified: Date)] {
        guard isRealDirectory(directory),
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return [] }
        var files: [(url: URL, size: Int64, modified: Date)] = []
        for name in names {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            guard let info = lstatInfo(url), (info.st_mode & S_IFMT) == S_IFREG else { continue }
            let seconds =
                Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9
            files.append((url, Int64(info.st_size), Date(timeIntervalSince1970: seconds)))
        }
        return files
    }
}
