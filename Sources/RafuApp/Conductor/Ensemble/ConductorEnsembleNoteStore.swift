import Darwin
import Foundation
import RafuCore

nonisolated enum ConductorEnsembleNoteStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidRunID
    case runDirectoryUnavailable
    case textTooLong
    case fileFull
    case invalidFile
    case systemCall(String, Int32)

    var errorDescription: String? {
        switch self {
        case .invalidRunID:
            "The Ensemble run identifier is invalid."
        case .runDirectoryUnavailable:
            "The Ensemble run directory is unavailable."
        case .textTooLong:
            "An Ensemble note must be at most 1000 characters."
        case .fileFull:
            "This run's Ensemble notes have reached the 256 KiB limit."
        case .invalidFile:
            "This run's Ensemble notes file is invalid."
        case .systemCall:
            "Rafu could not update this run's Ensemble notes."
        }
    }
}

nonisolated struct ConductorEnsembleNoteStore: Sendable {
    nonisolated struct Note: Codable, Equatable, Hashable, Sendable {
        let at: Date
        let from: String
        let text: String
    }

    static let maximumTextCharacters = 1_000
    static let maximumFileBytes = 256 * 1_024

    private let workspaceRoot: URL
    private let eventCenter: ConductorEnsembleEventCenter

    init(
        workspaceRoot: URL,
        eventCenter: ConductorEnsembleEventCenter
    ) {
        self.workspaceRoot = workspaceRoot.standardizedFileURL
        self.eventCenter = eventCenter
    }

    @concurrent
    func append(
        runID: String,
        from coordinatorID: String,
        text: String,
        at: Date = Date()
    ) async throws -> Note {
        guard ConductorRunStore.isValidRunID(runID) else {
            throw ConductorEnsembleNoteStoreError.invalidRunID
        }
        guard text.count <= Self.maximumTextCharacters else {
            throw ConductorEnsembleNoteStoreError.textTooLong
        }

        let runDirectory = runDirectory(runID)
        guard try Self.isRealDirectory(runDirectory) else {
            throw ConductorEnsembleNoteStoreError.runDirectoryUnavailable
        }

        let note = Note(at: at, from: coordinatorID, text: text)
        var line = try JSONEncoder().encode(note)
        line.append(0x0A)
        let notesURL = runDirectory.appending(path: "notes.jsonl", directoryHint: .notDirectory)
        let descriptor = try Self.openForAppend(notesURL)
        defer { Darwin.close(descriptor) }

        try Self.lock(descriptor)
        defer { Self.unlock(descriptor) }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            throw Self.systemCall("fstat")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw ConductorEnsembleNoteStoreError.invalidFile
        }
        guard status.st_size >= 0,
            Int64(line.count) <= Int64(Self.maximumFileBytes) - status.st_size
        else {
            throw ConductorEnsembleNoteStoreError.fileFull
        }

        try Self.writeAll(line, to: descriptor)
        await eventCenter.publish(
            EnsembleEvent(
                cursor: 0,
                at: at,
                runID: runID,
                kind: "note",
                note: text,
                startedBy: coordinatorID
            ))
        return note
    }

    @concurrent
    func read(runID: String) async throws -> [Note] {
        guard ConductorRunStore.isValidRunID(runID) else {
            throw ConductorEnsembleNoteStoreError.invalidRunID
        }
        let notesURL = runDirectory(runID)
            .appending(path: "notes.jsonl", directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: notesURL.path) else { return [] }
        let values = try notesURL.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= Self.maximumFileBytes
        else {
            throw ConductorEnsembleNoteStoreError.invalidFile
        }

        let handle = try FileHandle(forReadingFrom: notesURL)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumFileBytes + 1) ?? Data()
        guard data.count <= Self.maximumFileBytes else {
            throw ConductorEnsembleNoteStoreError.invalidFile
        }

        let decoder = JSONDecoder()
        return try data.split(separator: 0x0A).map { line in
            do {
                return try decoder.decode(Note.self, from: Data(line))
            } catch {
                throw ConductorEnsembleNoteStoreError.invalidFile
            }
        }
    }

    private func runDirectory(_ runID: String) -> URL {
        workspaceRoot
            .appending(path: ".rafu", directoryHint: .isDirectory)
            .appending(path: "runs", directoryHint: .isDirectory)
            .appending(path: runID, directoryHint: .isDirectory)
    }

    private static func isRealDirectory(_ url: URL) throws -> Bool {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func openForAppend(_ url: URL) throws -> Int32 {
        let descriptor = url.path.withCString { path in
            Darwin.open(
                path,
                O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(S_IRUSR | S_IWUSR)
            )
        }
        guard descriptor >= 0 else { throw systemCall("open") }
        return descriptor
    }

    private static func lock(_ descriptor: Int32) throws {
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_WRLCK),
            l_whence: Int16(SEEK_SET)
        )
        while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
            if errno == EINTR { continue }
            throw systemCall("fcntl")
        }
    }

    private static func unlock(_ descriptor: Int32) {
        var lock = flock(
            l_start: 0,
            l_len: 0,
            l_pid: 0,
            l_type: Int16(F_UNLCK),
            l_whence: Int16(SEEK_SET)
        )
        _ = Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(
                    descriptor,
                    bytes.baseAddress?.advanced(by: offset),
                    bytes.count - offset
                )
                if count < 0 {
                    if errno == EINTR { continue }
                    throw systemCall("write")
                }
                guard count > 0 else { throw systemCall("write") }
                offset += count
            }
        }
    }

    private static func systemCall(_ name: String) -> ConductorEnsembleNoteStoreError {
        .systemCall(name, errno)
    }
}
