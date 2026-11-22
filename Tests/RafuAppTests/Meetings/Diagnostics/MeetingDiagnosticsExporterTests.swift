import Foundation
import RafuCore
import Synchronization
import Testing

@testable import RafuApp

/// A presenter with scripted answers. No panel opens.
@MainActor
private final class ScriptedPresenter: MeetingDiagnosticsExportPresenting {
    var zipDestination: URL?
    var folderDestination: URL?
    var wantsFolder = false
    private(set) var panelMessages: [String] = []
    private(set) var suggestedNames: [String] = []
    private(set) var failures: [String] = []

    func chooseDestination(
        suggestedName: String, message: String, kind: MeetingDiagnosticsExporter.DestinationKind
    ) async -> URL? {
        suggestedNames.append(suggestedName)
        panelMessages.append(message)
        switch kind {
        case .zip: return zipDestination
        case .folder: return folderDestination
        }
    }

    func offerFolderInstead() async -> Bool { wantsFolder }

    func showFailure(_ message: String) { failures.append(message) }
}

private final class CapturingRecorder: MeetingDiagnosticsRecording {
    private let storage = Mutex<[MeetingDiagnosticEvent]>([])
    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        storage.withLock { $0.append(event) }
    }
    var events: [MeetingDiagnosticEvent] { storage.withLock { $0 } }
}

private struct ZipBroke: Error {}

@MainActor
@Suite("Meeting diagnostics: export flow")
struct MeetingDiagnosticsExporterTests {
    @MainActor
    private struct Rig {
        let root: URL
        let temporary: URL
        let writer: MeetingDiagnosticsFileWriter
        let presenter = ScriptedPresenter()
        let recorder = CapturingRecorder()
        let feature = MeetingsFeature(availability: .available)

        init() throws {
            root = FileManager.default.temporaryDirectory.appending(
                path: "rafu-exporter-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
            temporary = root.appending(path: "tmp", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: temporary, withIntermediateDirectories: true)
            writer = MeetingDiagnosticsFileWriter(
                directory: root.appending(path: "Diagnostics"), flushInterval: .seconds(3600),
                header: { MeetingDiagnosticsHeader.current().event })
            feature.register(.diagnosticsRecorder(recorder))
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        func temporaryNames() -> [String] {
            (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        }

        func exporter(
            zip: (@Sendable (URL, URL) async throws -> Void)? = nil
        ) -> MeetingDiagnosticsExporter {
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            if let zip {
                return MeetingDiagnosticsExporter(
                    writer: writer, presenter: presenter, now: { date },
                    temporaryDirectory: temporary, zip: zip)
            }
            return MeetingDiagnosticsExporter(
                writer: writer, presenter: presenter, now: { date },
                temporaryDirectory: temporary)
        }

        func unzipped(_ zip: URL) throws -> [URL] {
            let destination = root.appending(path: "unzipped-\(UUID().uuidString)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["-x", "-k", zip.path, destination.path]
            try process.run()
            process.waitUntilExit()
            let enumerator = FileManager.default.enumerator(
                at: destination, includingPropertiesForKeys: nil)
            return (enumerator?.allObjects as? [URL] ?? []).filter { !$0.hasDirectoryPath }
        }
    }

    @Test("The sheet text says what the bundle holds")
    func panelText() {
        #expect(
            MeetingDiagnosticsExporter.panelMessage
                == "Device names, app identifiers, error codes and timings. No transcript, no audio."
        )
    }

    @Test("Export with no meetings writes a zip with header.json, and removes the temporary folder")
    func exportZero() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let destination = rig.root.appending(path: "Rafu Meeting Diagnostics.zip")
        rig.presenter.zipDestination = destination

        let outcome = await rig.exporter().export(feature: rig.feature)

        #expect(outcome == .zip)
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(try rig.unzipped(destination).map(\.lastPathComponent) == ["header.json"])
        #expect(rig.temporaryNames().isEmpty)
        #expect(rig.presenter.suggestedNames.count == 1)
        #expect(rig.presenter.suggestedNames[0].hasPrefix("Rafu Meeting Diagnostics "))
        #expect(rig.presenter.suggestedNames[0].hasSuffix(".zip"))
        #expect(
            rig.presenter.panelMessages == [MeetingDiagnosticsExporter.panelMessage])
        #expect(rig.recorder.events == [.exportDone(kind: .diagnostics)])
        #expect(rig.presenter.failures.isEmpty)
    }

    @Test("Export includes the diagnostics files")
    func exportWithFiles() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        let meeting = MeetingID()
        let time = Date(timeIntervalSince1970: 1_700_000_000)
        await rig.writer.append(
            MeetingDiagnosticsEntry(
                meeting: meeting, event: .recordingPaused, time: time, clock: 1))
        await rig.writer.append(
            MeetingDiagnosticsEntry(meeting: nil, event: .recordingResumed, time: time, clock: nil))
        let destination = rig.root.appending(path: "out.zip")
        rig.presenter.zipDestination = destination

        #expect(await rig.exporter().export(feature: rig.feature) == .zip)
        let names = try rig.unzipped(destination).map(\.lastPathComponent).sorted()
        #expect(names == ["\(meeting.uuidString).jsonl", "app.jsonl", "header.json"].sorted())
    }

    @Test("Cancel writes nothing and removes the temporary folder")
    func cancelCleansUp() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.presenter.zipDestination = nil

        let outcome = await rig.exporter().export(feature: rig.feature)

        #expect(outcome == .cancelled)
        #expect(rig.temporaryNames().isEmpty)
        #expect(rig.recorder.events.isEmpty)
    }

    @Test(
        "When ditto fails the user can save the folder, and nothing stays in the temporary folder")
    func folderFallback() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.presenter.zipDestination = rig.root.appending(path: "out.zip")
        rig.presenter.wantsFolder = true
        let folder = rig.root.appending(path: "Saved Folder")
        rig.presenter.folderDestination = folder

        let outcome = await rig.exporter(zip: { _, _ in throw ZipBroke() })
            .export(feature: rig.feature)

        #expect(outcome == .folder)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "header.json").path))
        #expect(!FileManager.default.fileExists(atPath: rig.root.appending(path: "out.zip").path))
        #expect(rig.temporaryNames().isEmpty)
        #expect(
            rig.recorder.events.contains { event in
                if case .userFacingError(.export, _, _) = event { return true }
                return false
            })
        #expect(rig.recorder.events.last == .exportDone(kind: .diagnostics))
    }

    @Test("When ditto fails and the user declines the folder, nothing is written")
    func folderDeclined() async throws {
        let rig = try Rig()
        defer { rig.remove() }
        rig.presenter.zipDestination = rig.root.appending(path: "out.zip")
        rig.presenter.wantsFolder = false

        let outcome = await rig.exporter(zip: { _, _ in throw ZipBroke() })
            .export(feature: rig.feature)

        #expect(outcome == .cancelled)
        #expect(rig.temporaryNames().isEmpty)
        #expect(!rig.recorder.events.contains(.exportDone(kind: .diagnostics)))
    }

    @Test("The context holds fixed words and numbers only, with no engine reason text")
    func context() async {
        let feature = MeetingsFeature(availability: .available)
        let context = await MeetingDiagnosticsExporter.makeContext(
            feature: feature, date: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(context.textEngines.count == MeetingTextEngineID.allCases.count)
        #expect(context.textEngines.values.allSatisfy { $0 == "notRegistered" })
        #expect(context.speakerEngines.values.allSatisfy { $0 == "notRegistered" })
        #expect(context.models.values.allSatisfy { $0 == "unknown" })
        #expect(context.meetingCount == nil)
        #expect(
            Set(context.settings.keys)
                == ["textEngine", "speakerEngine", "microphone", "audioRetention", "agentAccess"])
        #expect(context.exportedAt == "2023-11-14T22:13:20.000Z")
    }
}
