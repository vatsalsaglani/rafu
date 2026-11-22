import AppKit
import RafuCore
import UniformTypeIdentifiers

/// How the exporter asks the user for a place and reports a failure. The
/// AppKit implementation is `MeetingDiagnosticsExportPanels`; tests inject a
/// fake.
@MainActor
protocol MeetingDiagnosticsExportPresenting {
    /// The place for the export, or nil when the user cancels.
    func chooseDestination(
        suggestedName: String, message: String, kind: MeetingDiagnosticsExporter.DestinationKind
    ) async -> URL?
    /// Asks whether to save the folder when the zip could not be made.
    func offerFolderInstead() async -> Bool
    func showFailure(_ message: String)
}

/// "Export Meeting Diagnostics…". Builds one bundle from the diagnostics
/// files and `header.json`, asks for a place with a save panel, and writes a
/// zip (or, when `ditto` fails and the user agrees, a folder). Nothing is
/// written or sent without the save panel, and the temporary folder is
/// removed on every path, also on Cancel.
@MainActor
final class MeetingDiagnosticsExporter {
    enum DestinationKind { case zip, folder }

    enum Outcome: Equatable {
        case zip
        case folder
        case cancelled
        case failed
    }

    /// The text of the save panel: what the bundle holds.
    static let panelMessage =
        "Device names, app identifiers, error codes and timings. No transcript, no audio."
    static let newestMeetingCount = 10

    private let writer: MeetingDiagnosticsFileWriter
    private let presenter: any MeetingDiagnosticsExportPresenting
    private let now: @Sendable () -> Date
    private let temporaryDirectory: URL
    /// Zips a folder; tests replace it to force a `ditto` failure.
    private let zip: @Sendable (URL, URL) async throws -> Void
    private var isRunning = false
    /// How many exports ran to the end (for tests).
    private(set) var completedCount = 0

    init(
        writer: MeetingDiagnosticsFileWriter,
        presenter: any MeetingDiagnosticsExportPresenting = MeetingDiagnosticsExportPanels(),
        now: @escaping @Sendable () -> Date = { Date() },
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        zip: @escaping @Sendable (URL, URL) async throws -> Void = {
            try await MeetingDiagnosticsExportBundle.zip(folder: $0, to: $1)
        }
    ) {
        self.writer = writer
        self.presenter = presenter
        self.now = now
        self.temporaryDirectory = temporaryDirectory
        self.zip = zip
    }

    /// Starts one export. A second call while one runs does nothing.
    func run(feature: MeetingsFeature) {
        guard !isRunning else { return }
        isRunning = true
        Task(name: "Export meeting diagnostics") {
            _ = await self.export(feature: feature)
            self.isRunning = false
        }
    }

    @discardableResult
    func export(feature: MeetingsFeature) async -> Outcome {
        defer { completedCount += 1 }
        let date = now()
        let name = MeetingDiagnosticsExportBundle.bundleName(for: date)
        let context = await Self.makeContext(feature: feature, date: date)
        let files = await writer.exportFiles(newestMeetings: Self.newestMeetingCount)

        let parent: URL
        let folder: URL
        do {
            (parent, folder) = try await MeetingDiagnosticsExportBundle.assemble(
                name: name, context: context, files: files,
                temporaryDirectory: temporaryDirectory)
        } catch {
            presenter.showFailure("Rafu could not prepare the diagnostics. No file was written.")
            record(feature, failureCode: (error as NSError).code)
            return .failed
        }
        // The temporary folder never outlives the export.
        defer { try? FileManager.default.removeItem(at: parent) }

        guard
            let zipURL = await presenter.chooseDestination(
                suggestedName: name + ".zip", message: Self.panelMessage, kind: .zip)
        else { return .cancelled }

        do {
            try await zip(folder, zipURL)
            feature.diagnostics.record(.exportDone(kind: .diagnostics), meeting: nil)
            return .zip
        } catch {
            record(feature, failureCode: Self.code(of: error))
        }

        // `ditto` failed: offer the folder.
        guard await presenter.offerFolderInstead(),
            let folderURL = await presenter.chooseDestination(
                suggestedName: name, message: Self.panelMessage, kind: .folder)
        else { return .cancelled }
        do {
            let manager = FileManager.default
            if manager.fileExists(atPath: folderURL.path) {
                try manager.removeItem(at: folderURL)
            }
            try manager.copyItem(at: folder, to: folderURL)
            feature.diagnostics.record(.exportDone(kind: .diagnostics), meeting: nil)
            return .folder
        } catch {
            presenter.showFailure("Rafu could not save the diagnostics folder.")
            record(feature, failureCode: (error as NSError).code)
            return .failed
        }
    }

    private func record(_ feature: MeetingsFeature, failureCode: Int) {
        feature.diagnostics.record(
            .userFacingError(place: .export, domain: "MeetingDiagnosticsExport", code: failureCode),
            meeting: nil)
    }

    private static func code(of error: Error) -> Int {
        if case MeetingDiagnosticsExportBundle.ExportError.zipFailed(let status) = error {
            return Int(status)
        }
        return (error as NSError).code
    }

    /// The facts of `header.json`. Fixed words and numbers only.
    static func makeContext(
        feature: MeetingsFeature, date: Date
    ) async -> MeetingDiagnosticsExportContext {
        var textEngines: [String: String] = [:]
        for id in MeetingTextEngineID.allCases {
            if let engine = feature.textEngines[id] {
                textEngines[id.rawValue] = MeetingDiagnosticsExportContext.word(
                    for: await engine.availability())
            } else {
                textEngines[id.rawValue] = "notRegistered"
            }
        }
        var speakerEngines: [String: String] = [:]
        for id in MeetingSpeakerEngineID.allCases {
            if let engine = feature.speakerEngines[id] {
                speakerEngines[id.rawValue] = MeetingDiagnosticsExportContext.word(
                    for: await engine.availability())
            } else {
                speakerEngines[id.rawValue] = "notRegistered"
            }
        }
        var models: [String: String] = [:]
        for id in MeetingModelID.allCases {
            if let locator = feature.modelLocator {
                models[id.rawValue] =
                    await locator.installedFolder(for: id) == nil ? "notInstalled" : "installed"
            } else {
                models[id.rawValue] = "unknown"
            }
        }
        let preferences = UserDefaultsMeetingPreferences()
        let speech = preferences.speechPreferences()
        let microphone: String
        switch preferences.microphoneChoice() {
        case .automatic: microphone = "automatic"
        case .systemDefault: microphone = "systemDefault"
        case .device: microphone = "namedDevice"
        }
        let settings = [
            "textEngine": speech.textEngine.rawValue,
            "speakerEngine": speech.speakerEngine.rawValue,
            "microphone": microphone,
            "audioRetention": preferences.audioRetention().rawValue,
            "agentAccess": preferences.agentAccess().rawValue,
        ]
        var meetingCount: Int?
        if let store = feature.store {
            meetingCount = try? await store.list().count
        }
        return MeetingDiagnosticsExportContext(
            exportedAt: date, header: .current(), textEngines: textEngines,
            speakerEngines: speakerEngines, models: models, settings: settings,
            meetingCount: meetingCount)
    }
}

/// The AppKit side of the export: the save panel and the alerts.
@MainActor
struct MeetingDiagnosticsExportPanels: MeetingDiagnosticsExportPresenting {
    func chooseDestination(
        suggestedName: String, message: String, kind: MeetingDiagnosticsExporter.DestinationKind
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.message = message
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        switch kind {
        case .zip: panel.allowedContentTypes = [.zip]
        case .folder: panel.allowedContentTypes = []
        }
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }

    /// A Rafu popup (every dialog uses the popup language); with no window
    /// to host it the answer is no, and nothing is written.
    func offerFolderInstead() async -> Bool {
        await CanvasDiagramPanels.confirm(
            symbol: "doc.zipper", title: "Zip File Not Made",
            message: "Rafu could not make the zip file. Save the diagnostics as a folder instead?",
            actionTitle: "Save Folder…")
    }

    func showFailure(_ message: String) {
        RafuPopupPresenter.presentMessage(title: "Export Meeting Diagnostics", message: message)
    }
}
