import Foundation
import Testing

@testable import RafuApp

/// The opt-in debug transcript: redaction, bounds, pruning and file modes.
@Suite("Voice debug transcript")
struct VoiceDebugTranscriptTests {
    static let fakeKey = "sk-test-FAKEKEY0123456789abcdef"

    @Test("Secret shapes in arguments and output are redacted")
    func redaction() async throws {
        let folder = TranscriptFolder()
        let transcript = VoiceDebugTranscript(directory: folder.url)
        transcript.record(
            .call(callID: "call_1", name: "note_write", arguments: #"{"text":"\#(Self.fakeKey)"}"#))
        transcript.record(
            .callResult(
                callID: "call_1", name: "note_write", summary: "ok", message: nil,
                output: "Bearer abc.def.ghi and \(Self.fakeKey)", isError: false))
        transcript.finish()
        await transcript.drained()
        let text = try String(contentsOf: transcript.fileURL, encoding: .utf8)
        #expect(!text.contains(Self.fakeKey))
        #expect(!text.contains("abc.def.ghi"))
        #expect(text.contains("[redacted]"))
        let lines = try Self.lines(transcript.fileURL)
        #expect(lines.map { $0["type"] as? String } == ["call", "call_result"])
        #expect(lines.allSatisfy { ($0["t"] as? String)?.isEmpty == false })
    }

    @Test("An oversized field is cut with a marker")
    func fieldTruncation() async throws {
        let folder = TranscriptFolder()
        let transcript = VoiceDebugTranscript(directory: folder.url)
        let long = String(repeating: "word ", count: VoiceDebugTranscript.maximumFieldBytes)
        transcript.record(.userSaid(long))
        transcript.finish()
        await transcript.drained()
        let line = try #require(try Self.lines(transcript.fileURL).first)
        let text = try #require(line["text"] as? String)
        let dropped = long.utf8.count - VoiceDebugTranscript.maximumFieldBytes
        #expect(text.hasSuffix("…[truncated \(dropped) bytes]"))
        #expect(text.utf8.count < VoiceDebugTranscript.maximumFieldBytes + 64)
    }

    @Test("The file cap writes one truncated line and nothing after it")
    func fileCap() async throws {
        let folder = TranscriptFolder()
        let transcript = VoiceDebugTranscript(directory: folder.url)
        let field = String(repeating: "x", count: VoiceDebugTranscript.maximumFieldBytes - 100)
        let count = VoiceDebugTranscript.maximumFileBytes / field.utf8.count + 10
        for index in 0..<count { transcript.record(.rafuSaid("\(index) \(field)")) }
        transcript.record(.sessionClosed(reason: "user"))
        transcript.finish()
        await transcript.drained()
        let size =
            try FileManager.default.attributesOfItem(atPath: transcript.fileURL.path)[
                .size] as? Int
        #expect((size ?? .max) <= VoiceDebugTranscript.maximumFileBytes)
        let lines = try Self.lines(transcript.fileURL)
        #expect(lines.last?["type"] as? String == "truncated")
        #expect(lines.count(where: { $0["type"] as? String == "truncated" }) == 1)
        #expect(!lines.contains { $0["type"] as? String == "session_closed" })
    }

    @Test("Pruning keeps exactly the newest keptFiles files; folder 0700, file 0600")
    func pruningAndModes() async throws {
        let folder = TranscriptFolder()
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        let old = Date(timeIntervalSince1970: 1_700_000_000)
        var names: [String] = []
        for index in 0..<(VoiceDebugTranscript.keptFiles + 5) {
            let name = VoiceDebugTranscript.fileName(for: old.addingTimeInterval(Double(index)))
            names.append(name)
            FileManager.default.createFile(
                atPath: folder.url.appending(path: name).path, contents: Data("{}\n".utf8))
        }
        FileManager.default.createFile(
            atPath: folder.url.appending(path: "notes.txt").path, contents: Data())
        let transcript = VoiceDebugTranscript(directory: folder.url)
        transcript.record(.sessionStarted(id: "sess_1"))
        transcript.finish()
        await transcript.drained()
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.url.path)
        let kept = left.filter { $0.hasPrefix("voice-") }
        #expect(kept.count == VoiceDebugTranscript.keptFiles)
        #expect(kept.contains(transcript.fileURL.lastPathComponent))
        // The oldest go first.
        #expect(!kept.contains(names[0]))
        #expect(kept.contains(try #require(names.last)))
        #expect(left.contains("notes.txt"))
        #expect(try Self.mode(folder.url) == 0o700)
        #expect(try Self.mode(transcript.fileURL) == 0o600)
    }

    @Test("Rafu and Rafu Lightning write to different folders")
    func folders() {
        let path = VoiceDebugTranscript.defaultDirectory().path
        #expect(path.hasSuffix("/Voice"))
        #expect(VoiceDebugTranscript.displayPath().hasPrefix("~/Library/"))
        #expect(VoiceDebugTranscript.fileName(for: .now).hasPrefix("voice-"))
        #expect(VoiceDebugTranscript.fileName(for: .now).hasSuffix(".jsonl"))
    }

    // MARK: Helpers

    static func lines(_ url: URL) throws -> [[String: Any]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        }
    }

    static func mode(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }
}

/// A temporary folder that does not exist yet, removed afterwards.
final class TranscriptFolder: Sendable {
    let url = FileManager.default.temporaryDirectory.appending(
        path: "rafu-voice-transcript-\(UUID().uuidString)", directoryHint: .isDirectory)
    deinit { try? FileManager.default.removeItem(at: url) }
}
