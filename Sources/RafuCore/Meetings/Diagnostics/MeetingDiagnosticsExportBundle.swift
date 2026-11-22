import Foundation

/// The facts of `header.json` in an export, besides the Mac and Rafu facts:
/// engine and model install states, the Settings ▸ Meetings values and the
/// number of meetings. Each value is a fixed word or a number; none is
/// meeting content.
public struct MeetingDiagnosticsExportContext: Codable, Hashable, Sendable {
    public var formatVersion = 1
    public var exportedAt: String
    public var header: MeetingDiagnosticsHeader
    /// Text engine id → `ready`, `needsModel` or `unavailable`.
    public var textEngines: [String: String]
    /// Speaker engine id → `ready`, `needsModel` or `unavailable`.
    public var speakerEngines: [String: String]
    /// Model id → `installed` or `notInstalled`.
    public var models: [String: String]
    /// Settings ▸ Meetings values as fixed words.
    public var settings: [String: String]
    /// The number of meetings in the library, when it could be read.
    public var meetingCount: Int?

    public init(
        exportedAt: Date, header: MeetingDiagnosticsHeader, textEngines: [String: String],
        speakerEngines: [String: String], models: [String: String], settings: [String: String],
        meetingCount: Int?
    ) {
        self.exportedAt = MeetingDiagnosticsEncoder.timestamp(exportedAt)
        self.header = header
        self.textEngines = textEngines
        self.speakerEngines = speakerEngines
        self.models = models
        self.settings = settings
        self.meetingCount = meetingCount
    }

    /// An availability as a fixed word (the engine's own reason text is not
    /// exported).
    public static func word(for availability: MeetingEngineAvailability) -> String {
        switch availability {
        case .ready: "ready"
        case .needsModel: "needsModel"
        case .unavailable: "unavailable"
        }
    }
}

/// Builds the export bundle: a folder with `header.json` and the diagnostics
/// files, and a zip of that folder made by `/usr/bin/ditto`.
public enum MeetingDiagnosticsExportBundle {
    public enum ExportError: Error, Equatable {
        case zipFailed(status: Int32)
        case zipLaunchFailed
    }

    public static let headerFileName = "header.json"

    /// `Rafu Meeting Diagnostics <yyyy-MM-dd>` (local date), the folder inside
    /// the zip. The zip file adds `.zip`.
    public static func bundleName(for date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "Rafu Meeting Diagnostics %04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0)
    }

    /// Makes `<parent>/<name>/` (mode 0700) with `header.json` and a copy of
    /// each file, and returns the folder. `parent` must exist and should be a
    /// private temporary folder; the caller removes it.
    public static func makeFolder(
        in parent: URL, name: String, context: MeetingDiagnosticsExportContext, files: [URL]
    ) throws -> URL {
        let manager = FileManager.default
        let folder = parent.appending(path: name, directoryHint: .isDirectory)
        try manager.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let header = try encoder.encode(context)
        try header.write(to: folder.appending(path: headerFileName), options: .atomic)
        for file in files {
            try manager.copyItem(
                at: file, to: folder.appending(path: file.lastPathComponent))
        }
        return folder
    }

    /// Makes a private temporary parent and builds the bundle folder in it,
    /// off the caller's actor. When the build fails the parent is removed
    /// here; on success the caller removes `parent` on each path.
    @concurrent
    public static func assemble(
        name: String, context: MeetingDiagnosticsExportContext, files: [URL],
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) async throws -> (parent: URL, folder: URL) {
        let parent = try makeTemporaryParent(in: temporaryDirectory)
        do {
            let folder = try makeFolder(in: parent, name: name, context: context, files: files)
            return (parent, folder)
        } catch {
            try? FileManager.default.removeItem(at: parent)
            throw error
        }
    }

    /// A new private temporary folder to build a bundle in.
    public static func makeTemporaryParent(
        in temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        let url = temporaryDirectory.appending(
            path: "rafu-meeting-diagnostics-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    /// Zips `folder` (with the folder as the top item) to `zipURL`. Runs
    /// `/usr/bin/ditto -c -k --keepParent` with an argument array.
    public static func zip(folder: URL, to zipURL: URL) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-c", "-k", "--keepParent", folder.path, zipURL.path]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { finished in
                continuation.resume(returning: finished.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: ExportError.zipLaunchFailed)
            }
        }
        guard status == 0 else { throw ExportError.zipFailed(status: status) }
    }
}
