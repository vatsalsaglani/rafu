import Foundation
import RafuCore
import Testing

@Suite("Meetings speech worker request check")
struct MeetingWorkerRequestValidationTests {
    /// A temporary folder with no symbolic link in its path. `/var` is a
    /// link to `/private/var`, and `URL.resolvingSymlinksInPath()` maps
    /// `/private/var` back to `/var`, so `realpath(3)` resolves it.
    private static func makeRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-worker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        guard let resolved = realpath(raw.path, nil) else { return raw }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func makeModel(_ engine: MeetingWorkerEngineID, in root: URL) throws -> URL {
        let folder = root.appendingPathComponent(engine.rawValue, isDirectory: true)
        for entry in MeetingWorkerModelLayout.requiredEntries(for: engine) {
            let url = folder.appendingPathComponent(entry)
            if entry.hasSuffix(".mlmodelc") || !entry.contains(".") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("{}".utf8).write(to: url)
            }
        }
        return folder
    }

    private static func makeAudio(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("them.wav")
        try Data([0, 1, 2]).write(to: url)
        return url
    }

    @Test("A complete request for each engine passes")
    func validRequests() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = try Self.makeAudio(in: root)
        for engine in MeetingWorkerEngineID.allCases {
            let folder = try Self.makeModel(engine, in: root)
            for mode in engine.supportedModes {
                let request = MeetingWorkerRequest(
                    engine: engine, modelFolder: folder.path,
                    audioFile: mode.readsAudioFile ? audio.path : nil)
                try request.validate(for: mode)
            }
        }
    }

    @Test("A relative model path is refused with exit 65")
    func relativePathRefused() {
        for path in ["models/nemotron", "./models", "/Users/../etc"] {
            let request = MeetingWorkerRequest(engine: .nemotronEnglish, modelFolder: path)
            #expect(throws: MeetingWorkerRequestError.relativePath) {
                try request.validate(for: .liveText)
            }
        }
        #expect(MeetingWorkerRequestError.relativePath.exitCode == .badRequest)
        #expect(MeetingWorkerRequestError.relativePath.exitCode.rawValue == 65)
    }

    @Test("A symbolic link in any part of the model path is refused with exit 65")
    func symbolicLinkRefused() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.makeModel(.nemotron3, in: root)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let direct = MeetingWorkerRequest(
            engine: .nemotron3, modelFolder: link.path, audioFile: try Self.makeAudio(in: root).path
        )
        #expect(throws: MeetingWorkerRequestError.symbolicLinkInPath) {
            try direct.validate(for: .speakers)
        }
        let parentLink = root.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        let inner = MeetingWorkerRequest(
            engine: .nemotron3, modelFolder: parentLink.appendingPathComponent("nemotron-3").path,
            audioFile: root.appendingPathComponent("them.wav").path)
        #expect(throws: MeetingWorkerRequestError.symbolicLinkInPath) {
            try inner.validate(for: .speakers)
        }
        #expect(MeetingWorkerRequestError.symbolicLinkInPath.exitCode.rawValue == 65)
    }

    @Test("A missing folder or a missing model file is exit 66")
    func missingModel() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = MeetingWorkerRequest(
            engine: .nemotronEnglish, modelFolder: root.appendingPathComponent("absent").path)
        #expect(throws: MeetingWorkerRequestError.modelMissing) {
            try missing.validate(for: .liveText)
        }
        let folder = try Self.makeModel(.whisperKit, in: root)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("tokenizer.json"))
        let incomplete = MeetingWorkerRequest(
            engine: .whisperKit, modelFolder: folder.path,
            audioFile: try Self.makeAudio(in: root).path)
        #expect(throws: MeetingWorkerRequestError.modelMissing) {
            try incomplete.validate(for: .finalText)
        }
        #expect(MeetingWorkerRequestError.modelMissing.exitCode.rawValue == 66)
        #expect(
            MeetingWorkerModelLayout.missingEntries(for: .whisperKit, in: folder) == [
                "tokenizer.json"
            ])
    }

    @Test("The audio file must be a file, and only the file modes take one")
    func audioFileRules() throws {
        let root = try Self.makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = try Self.makeModel(.nemotronEnglish, in: root)
        let audio = try Self.makeAudio(in: root)
        #expect(throws: MeetingWorkerRequestError.audioFileNotAllowed) {
            try MeetingWorkerRequest(
                engine: .nemotronEnglish, modelFolder: folder.path, audioFile: audio.path
            ).validate(for: .liveText)
        }
        #expect(throws: MeetingWorkerRequestError.audioFileMissing) {
            try MeetingWorkerRequest(engine: .nemotronEnglish, modelFolder: folder.path)
                .validate(for: .finalText)
        }
        #expect(throws: MeetingWorkerRequestError.notAFile) {
            try MeetingWorkerRequest(
                engine: .nemotronEnglish, modelFolder: folder.path, audioFile: root.path
            ).validate(for: .finalText)
        }
        #expect(throws: MeetingWorkerRequestError.relativePath) {
            try MeetingWorkerRequest(
                engine: .nemotronEnglish, modelFolder: folder.path, audioFile: "them.wav"
            ).validate(for: .finalText)
        }
    }

    @Test("An engine in the wrong mode is refused")
    func engineModeRefused() throws {
        let request = MeetingWorkerRequest(engine: .whisperKit, modelFolder: "/m")
        #expect(throws: MeetingWorkerRequestError.engineNotForMode) {
            try request.validateShape(for: .liveText)
        }
        let speakers = MeetingWorkerRequest(engine: .nemotron3, modelFolder: "/m", audioFile: "/a")
        #expect(throws: MeetingWorkerRequestError.engineNotForMode) {
            try speakers.validateShape(for: .finalText)
        }
    }
}
