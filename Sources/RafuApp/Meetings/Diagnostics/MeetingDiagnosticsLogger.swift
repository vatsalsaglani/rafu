import OSLog
import RafuCore

/// The `Logger` mirror of the meeting diagnostics. Subsystem
/// `dev.vatsalsaglani.rafu`, category `meetings`. This is the only file under
/// `Meetings/` that may log (a source-scan test keeps it so).
///
/// Each line is the event name, its numbers and fixed labels (public), and
/// then the `MeetingDiagnosticString` facts such as a device name (private).
/// Read it with:
/// `/usr/bin/log stream --predicate 'subsystem == "dev.vatsalsaglani.rafu" AND category == "meetings"'`
nonisolated struct MeetingDiagnosticsLogger: MeetingDiagnosticsLogSink {
    static let subsystem = "dev.vatsalsaglani.rafu"
    static let category = "meetings"

    private let logger = Logger(subsystem: subsystem, category: category)

    func log(_ description: MeetingDiagnosticDescription, meeting: MeetingID?) {
        let text = MeetingDiagnosticLogText(description)
        let meetingText = meeting.map { String($0.uuidString.prefix(8)) } ?? "-"
        logger.info(
            "\(description.name, privacy: .public) meeting=\(meetingText, privacy: .public) \(text.publicText, privacy: .public) \(text.privateText, privacy: .private)"
        )
    }
}
