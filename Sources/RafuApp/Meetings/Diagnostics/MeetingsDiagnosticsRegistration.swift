import Foundation
import RafuCore

// Owned by the meeting diagnostics log and export package.
// `MeetingsFeature.registerBuiltInParts()` calls this function; the package
// registers its parts here with `register(_:)` and never edits
// `MeetingsFeature.swift`.

/// The diagnostics folder and the objects that use it: the file writer, the
/// recorder that other packages call, and the exporter.
@MainActor
final class MeetingsDiagnosticsRuntime {
    let writer: MeetingDiagnosticsFileWriter
    let recorder: MeetingDiagnosticsRecorder
    let exporter: MeetingDiagnosticsExporter

    /// `applicationSupportRoot()/Meetings/Diagnostics`, the only place the
    /// diagnostics files live.
    static func defaultDirectory(identity: RafuAppIdentity = .current) -> URL {
        identity.applicationSupportRoot()
            .appending(path: "Meetings", directoryHint: .isDirectory)
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    init(
        directory: URL = MeetingsDiagnosticsRuntime.defaultDirectory(),
        presenter: any MeetingDiagnosticsExportPresenting = MeetingDiagnosticsExportPanels()
    ) {
        let writer = MeetingDiagnosticsFileWriter(
            directory: directory,
            header: { MeetingDiagnosticsHeader.current().event })
        self.writer = writer
        self.recorder = MeetingDiagnosticsRecorder(
            writer: writer, logSink: MeetingDiagnosticsLogger())
        self.exporter = MeetingDiagnosticsExporter(writer: writer, presenter: presenter)
    }
}

extension MeetingsFeature {
    func registerDiagnosticsParts() {
        let runtime = MeetingsDiagnosticsRuntime()
        register(.diagnosticsRecorder(runtime.recorder))
        register(.diagnosticsExporter { feature in runtime.exporter.run(feature: feature) })
    }
}
