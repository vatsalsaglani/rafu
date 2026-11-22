import Foundation

/// Why the helper refused a request (exit code 65 or 66).
public enum MeetingWorkerRequestError: Error, Equatable, Sendable {
    case tooLarge
    case notJSON
    case wrongProtocol
    case engineNotInHelper
    case engineNotForMode
    case relativePath
    case symbolicLinkInPath
    case notAFolder
    case notAFile
    case audioFileNotAllowed
    case audioFileMissing
    case modelMissing

    /// The exit code that the helper uses for this error.
    public var exitCode: MeetingWorkerExitCode {
        switch self {
        case .modelMissing: .modelMissing
        default: .badRequest
        }
    }

    /// The short, stable code in an `error` line (never user text).
    public var wireCode: Int {
        switch self {
        case .tooLarge: 1
        case .notJSON: 2
        case .wrongProtocol: 3
        case .engineNotInHelper: 4
        case .engineNotForMode: 5
        case .relativePath: 6
        case .symbolicLinkInPath: 7
        case .notAFolder: 8
        case .notAFile: 9
        case .audioFileNotAllowed: 10
        case .audioFileMissing: 11
        case .modelMissing: 12
        }
    }
}

/// The one request line on standard input.
public struct MeetingWorkerRequest: Codable, Equatable, Sendable {
    public var protocolVersion: Int
    public var engine: MeetingWorkerEngineID
    /// An absolute folder path from `MeetingModelLocating`. The helper checks
    /// that it is a folder and that no part of it is a symbolic link.
    public var modelFolder: String
    /// The stored audio of one track (the file modes only), an absolute
    /// path in Rafu's app data.
    public var audioFile: String?
    /// Seconds on the meeting clock of the first sample of `audioFile`.
    public var clockOffsetSeconds: Double
    /// The Nemotron chunk length in milliseconds (1120 is the only tier).
    public var chunkMilliseconds: Int

    public init(
        engine: MeetingWorkerEngineID, modelFolder: String, audioFile: String? = nil,
        clockOffsetSeconds: Double = 0, chunkMilliseconds: Int = 1_120
    ) {
        self.protocolVersion = MeetingWorkerProtocol.version
        self.engine = engine
        self.modelFolder = modelFolder
        self.audioFile = audioFile
        self.clockOffsetSeconds = clockOffsetSeconds
        self.chunkMilliseconds = chunkMilliseconds
    }

    /// The request as one line of JSON with a final newline.
    public func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        guard data.count <= MeetingWorkerProtocol.maximumRequestBytes else {
            throw MeetingWorkerRequestError.tooLarge
        }
        data.append(0x0A)
        return data
    }

    /// Decodes one request line (without its newline).
    public static func decode(line: Data) throws(MeetingWorkerRequestError) -> MeetingWorkerRequest
    {
        guard line.count <= MeetingWorkerProtocol.maximumRequestBytes else { throw .tooLarge }
        let request: MeetingWorkerRequest
        do {
            request = try JSONDecoder().decode(MeetingWorkerRequest.self, from: line)
        } catch {
            throw .notJSON
        }
        guard request.protocolVersion == MeetingWorkerProtocol.version else {
            throw .wrongProtocol
        }
        return request
    }

    /// Checks the request against the mode, with no file system access.
    public func validateShape(for mode: MeetingWorkerMode) throws(MeetingWorkerRequestError) {
        guard engine.supportedModes.contains(mode) else { throw .engineNotForMode }
        guard modelFolder.hasPrefix("/") else { throw .relativePath }
        if mode.readsAudioFile {
            guard let audioFile else { throw .audioFileMissing }
            guard audioFile.hasPrefix("/") else { throw .relativePath }
        } else if audioFile != nil {
            throw .audioFileNotAllowed
        }
        guard clockOffsetSeconds.isFinite, clockOffsetSeconds >= 0 else { throw .notJSON }
        guard chunkMilliseconds > 0, chunkMilliseconds <= 10_000 else { throw .notJSON }
    }

    /// Checks the shape and then the file system: the model folder is a
    /// folder with the files its engine loads, the audio file is a regular
    /// file, and no part of either path is a symbolic link.
    public func validate(for mode: MeetingWorkerMode) throws(MeetingWorkerRequestError) {
        try validateShape(for: mode)
        try MeetingWorkerPathCheck.check(path: modelFolder, expect: .folder)
        if let audioFile, mode.readsAudioFile {
            try MeetingWorkerPathCheck.check(path: audioFile, expect: .file)
        }
        let missing = MeetingWorkerModelLayout.missingEntries(
            for: engine, in: URL(fileURLWithPath: modelFolder, isDirectory: true))
        guard missing.isEmpty else { throw .modelMissing }
    }
}

/// The path rule of the helper.
public enum MeetingWorkerPathCheck {
    public enum Expectation: Sendable {
        case folder
        case file
    }

    /// Refuses a relative path, a path with `.` or `..` parts, a path with
    /// a symbolic link in any part, and a path of the wrong kind. A missing
    /// model folder is `modelMissing` (exit 66).
    public static func check(path: String, expect: Expectation) throws(MeetingWorkerRequestError) {
        guard path.hasPrefix("/") else { throw .relativePath }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == "." || $0 == ".." }) else { throw .relativePath }
        var current = ""
        for (index, part) in parts.enumerated() {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0 else {
                throw expect == .folder ? .modelMissing : .notAFile
            }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK { throw .symbolicLinkInPath }
            let isLast = index == parts.count - 1
            if !isLast {
                guard type == S_IFDIR else { throw expect == .folder ? .notAFolder : .notAFile }
            } else {
                switch expect {
                case .folder: guard type == S_IFDIR else { throw .notAFolder }
                case .file: guard type == S_IFREG else { throw .notAFile }
                }
            }
        }
        if parts.isEmpty { throw expect == .folder ? .notAFolder : .notAFile }
    }
}

/// The files that each engine's local load call needs, relative to the
/// model folder. The helper checks them before it loads, so a missing file
/// is exit 66 and never a library call that might try the network.
public enum MeetingWorkerModelLayout {
    public static func requiredEntries(for engine: MeetingWorkerEngineID) -> [String] {
        switch engine {
        case .nemotronEnglish:
            // `StreamingNemotronAsrManager.loadModels(from:)`: a flat folder.
            [
                "metadata.json", "tokenizer.json", "decoder.mlmodelc", "joint.mlmodelc",
                "encoder/encoder_int8_v2.mlmodelc",
            ]
        case .whisperKit:
            // `WhisperKitConfig(modelFolder:)`: the tokenizer files must sit
            // directly in the model folder, else
            // `configurationMissing("tokenizer.json")`.
            [
                "AudioEncoder.mlmodelc", "MelSpectrogram.mlmodelc", "TextDecoder.mlmodelc",
                "config.json", "tokenizer.json",
            ]
        case .nemotron3:
            // `Nemotron3Models.load(config:directory:)`: bundle and the
            // silence embedding side by side.
            ["Nemotron3Diarizer_fast32.mlmodelc", "learnable_sil_emb.bin"]
        case .speakerKit:
            // `PyannoteConfig(modelFolder:)`: the repository's nested tree.
            ["speaker_segmenter", "speaker_embedder", "speaker_clusterer"]
        }
    }

    /// The required entries that are not in `folder`.
    public static func missingEntries(for engine: MeetingWorkerEngineID, in folder: URL) -> [String]
    {
        requiredEntries(for: engine).filter { entry in
            !FileManager.default.fileExists(atPath: folder.appendingPathComponent(entry).path)
        }
    }
}
