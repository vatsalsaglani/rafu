import Foundation
import RafuCore

/// The opt-in debug transcript (Settings ▸ Voice ▸ Debugging; ADR 0035
/// amendment). One JSONL file per voice session: what the user said, what
/// Rafu said, and every tool call with its arguments and result. It never
/// receives the key, request headers or audio.
///
/// `record` only yields to one ordered stream, so the main actor never
/// waits for the disk. One drain task owns the file: it creates the folder
/// (0700) and the file (0600), keeps the newest `keptFiles` files, redacts
/// secret shapes, bounds every field and the whole file, and closes the file
/// when the stream ends.
nonisolated struct VoiceDebugTranscript: Sendable {
    enum Entry: Sendable {
        case sessionOpened(persona: String, backend: String, voice: String)
        case sessionStarted(id: String)
        case sessionClosed(reason: String)
        case sessionFailed(reason: String)
        case serverError(code: String?, message: String?)
        case userSaid(String)
        case rafuSaid(String)
        case delegation(id: String, target: String?)
        case call(callID: String, name: String, arguments: String)
        case callResult(
            callID: String, name: String, summary: String, message: String?, output: String,
            isError: Bool)
        case confirm(tool: String, answer: String)
    }

    /// One entry with the time it was recorded, not the time it was written.
    struct Line: Sendable {
        let date: Date
        let entry: Entry
    }

    static let maximumFileBytes = 2 * 1_024 * 1_024
    static let maximumFieldBytes = 16 * 1_024
    static let keptFiles = 20
    /// Entries waiting for the disk. Only a stalled disk fills it; the
    /// oldest entries then go.
    static let bufferedEntries = 1_024
    static let filePrefix = "voice-"
    static let fileExtension = "jsonl"

    /// `~/Library/Logs/<app name>/Voice`, so Rafu and Rafu Lightning never
    /// share a folder.
    static func defaultDirectory(identity: RafuAppIdentity = .current) -> URL {
        let library =
            FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        return library.appending(path: "Logs", directoryHint: .isDirectory)
            .appending(path: identity.displayName, directoryHint: .isDirectory)
            .appending(path: "Voice", directoryHint: .isDirectory)
    }

    /// The folder as the Settings footer shows it.
    static func displayPath(identity: RafuAppIdentity = .current) -> String {
        "~/Library/Logs/\(identity.displayName)/Voice"
    }

    let fileURL: URL
    private let continuation: AsyncStream<Line>.Continuation
    private let drainTask: Task<Void, Never>

    init(directory: URL, now: Date = .now) {
        let fileURL = directory.appending(path: Self.fileName(for: now))
        let (stream, continuation) = AsyncStream.makeStream(
            of: Line.self, bufferingPolicy: .bufferingNewest(Self.bufferedEntries))
        self.fileURL = fileURL
        self.continuation = continuation
        drainTask = Task {
            await Self.drain(stream, directory: directory, fileURL: fileURL)
        }
    }

    /// Synchronous and ordered; never waits for the disk.
    func record(_ entry: Entry) {
        continuation.yield(Line(date: .now, entry: entry))
    }

    /// Ends the stream; the drain writes what is left and closes the file.
    func finish() { continuation.finish() }

    /// Waits until the drain closed the file. Tests use it after `finish`.
    func drained() async { await drainTask.value }

    // MARK: File

    static func fileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let suffix = String(format: "%04x", UInt16.random(in: .min ... .max))
        return "\(filePrefix)\(formatter.string(from: date))-\(suffix).\(fileExtension)"
    }

    @concurrent
    static func drain(_ stream: AsyncStream<Line>, directory: URL, fileURL: URL) async {
        guard let handle = openFile(directory: directory, fileURL: fileURL) else {
            for await _ in stream {}
            return
        }
        defer { try? handle.close() }
        // Room for the `truncated` line is reserved, so it always fits.
        let reserved = truncatedLine(at: .now)?.count ?? 0
        var written = 0
        var isFull = false
        for await line in stream {
            guard !isFull, let data = encode(line) else { continue }
            if written + data.count + reserved > maximumFileBytes {
                isFull = true
                if let truncated = truncatedLine(at: line.date) {
                    try? handle.write(contentsOf: truncated)
                }
                continue
            }
            do {
                try handle.write(contentsOf: data)
                written += data.count
            } catch {
                isFull = true
            }
        }
    }

    /// Creates the folder (0700) and the file (0600), after pruning old
    /// files so that, with the new one, `keptFiles` remain.
    private static func openFile(directory: URL, fileURL: URL) -> FileHandle? {
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } catch {
            return nil
        }
        prune(directory: directory, keeping: keptFiles - 1)
        guard
            manager.createFile(
                atPath: fileURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { return nil }
        return try? FileHandle(forWritingTo: fileURL)
    }

    /// Deletes all but the newest `count` transcript files. Names start with
    /// the date, so name order is age order.
    static func prune(directory: URL, keeping count: Int) {
        let manager = FileManager.default
        guard
            let names = try? manager.contentsOfDirectory(atPath: directory.path)
        else { return }
        let transcripts =
            names
            .filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".\(fileExtension)") }
            .sorted(by: >)
        for name in transcripts.dropFirst(max(0, count)) {
            try? manager.removeItem(at: directory.appending(path: name))
        }
    }

    // MARK: Encoding

    private static func truncatedLine(at date: Date) -> Data? {
        line(["t": timestamp(date), "type": "truncated"])
    }

    static func encode(_ line: Line) -> Data? {
        var object = fields(line.entry)
        object["t"] = timestamp(line.date)
        return Self.line(object)
    }

    private static func line(_ object: [String: Any]) -> Data? {
        guard
            var data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        data.append(0x0A)
        return data
    }

    private static func timestamp(_ date: Date) -> String {
        Date.ISO8601FormatStyle(includingFractionalSeconds: true).format(date)
    }

    private static func fields(_ entry: Entry) -> [String: Any] {
        var object: [String: Any]
        switch entry {
        case .sessionOpened(let persona, let backend, let voice):
            object = [
                "type": "session_opened", "persona": clean(persona), "backend": clean(backend),
                "voice": clean(voice),
            ]
        case .sessionStarted(let id):
            object = ["type": "session_started", "session_id": clean(id)]
        case .sessionClosed(let reason):
            object = ["type": "session_closed", "reason": clean(reason)]
        case .sessionFailed(let reason):
            object = ["type": "session_failed", "reason": clean(reason)]
        case .serverError(let code, let message):
            object = ["type": "server_error"]
            object["code"] = code.map(clean)
            object["message"] = message.map(clean)
        case .userSaid(let text):
            object = ["type": "user_said", "text": clean(text)]
        case .rafuSaid(let text):
            object = ["type": "rafu_said", "text": clean(text)]
        case .delegation(let id, let target):
            object = ["type": "delegation", "delegation_id": clean(id)]
            object["target"] = target.map(clean)
        case .call(let callID, let name, let arguments):
            object = [
                "type": "call", "call_id": clean(callID), "name": clean(name),
                "arguments": clean(arguments),
            ]
        case .callResult(let callID, let name, let summary, let message, let output, let isError):
            object = [
                "type": "call_result", "call_id": clean(callID), "name": clean(name),
                "summary": clean(summary), "output": clean(output), "is_error": isError,
            ]
            object["message"] = message.map(clean)
        case .confirm(let tool, let answer):
            object = ["type": "confirm", "tool": clean(tool), "answer": clean(answer)]
        }
        return object
    }

    /// Secret shapes become `[redacted]`; then the field is cut to
    /// `maximumFieldBytes` of UTF-8 with a marker that says how much went.
    static func clean(_ text: String) -> String {
        let redacted = VoiceOutputScrubber.redactSecrets(text)
        let total = redacted.utf8.count
        guard total > maximumFieldBytes else { return redacted }
        var kept = String.UnicodeScalarView()
        var bytes = 0
        for scalar in redacted.unicodeScalars {
            let size = String(scalar).utf8.count
            if bytes + size > maximumFieldBytes { break }
            kept.append(scalar)
            bytes += size
        }
        return String(kept) + "…[truncated \(total - bytes) bytes]"
    }
}
