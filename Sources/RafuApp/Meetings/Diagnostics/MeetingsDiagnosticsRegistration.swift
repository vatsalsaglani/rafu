import AppKit
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

    /// The runtime of the app's feature, kept so the quit observer reaches it.
    private(set) static var current: MeetingsDiagnosticsRuntime?
    private static var quitObserver: (any NSObjectProtocol)?

    /// Keeps this runtime and writes its queued events at app quit, so the
    /// last events of a session are on disk for the next export.
    func installQuitFlush() {
        Self.current = self
        if let old = Self.quitObserver { NotificationCenter.default.removeObserver(old) }
        let recorder = recorder
        Self.quitObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            Self.flushBeforeQuit(recorder)
        }
    }

    /// Writes each queued event to disk and waits at most `timeout`. The
    /// quit notification is synchronous; the flush runs on no main-actor
    /// code, so the short wait cannot block it. Returns false on timeout.
    @discardableResult
    nonisolated static func flushBeforeQuit(
        _ recorder: MeetingDiagnosticsRecorder, timeout: DispatchTimeInterval = .seconds(1)
    ) -> Bool {
        let done = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            await recorder.flush()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout) == .success
    }
}

extension MeetingsFeature {
    func registerDiagnosticsParts() {
        let runtime = MeetingsDiagnosticsRuntime()
        runtime.installQuitFlush()
        register(.diagnosticsRecorder(runtime.recorder))
        register(.diagnosticsExporter { feature in runtime.exporter.run(feature: feature) })
    }
}
