import Foundation
import Synchronization

@testable import RafuCore

/// A temporary library root for one test. Every test passes this root to
/// the store, so no test touches the real app data.
struct LibraryFixture {
    let base: URL
    let root: URL
    let diagnosticsDirectory: URL
    let snapshotRoot: URL

    init() {
        base = FileManager.default.temporaryDirectory
            .appending(path: "rafu-library-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "Meetings", directoryHint: .isDirectory)
            .appending(path: "Library", directoryHint: .isDirectory)
        diagnosticsDirectory = base.appending(path: "Meetings", directoryHint: .isDirectory)
            .appending(path: "Diagnostics", directoryHint: .isDirectory)
        snapshotRoot = base.appending(path: "Snapshots", directoryHint: .isDirectory)
    }

    func makeStore(
        diagnostics: any MeetingDiagnosticsRecording = NoopMeetingDiagnostics(),
        clock: @escaping @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
    ) -> MeetingStore {
        MeetingStore(
            rootDirectory: root, diagnosticsDirectory: diagnosticsDirectory,
            snapshotRoot: snapshotRoot, diagnostics: diagnostics, clock: clock)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }

    func folder(of meeting: MeetingID) -> URL {
        root.appending(path: meeting.uuidString, directoryHint: .isDirectory)
    }

    func file(_ name: String, of meeting: MeetingID) -> URL {
        folder(of: meeting).appending(path: name, directoryHint: .notDirectory)
    }

    /// The POSIX permission bits of a path.
    static func mode(of url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return ((attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
    }
}

/// A diagnostics recorder that keeps each event, for tests.
final class RecordingMeetingDiagnostics: MeetingDiagnosticsRecording {
    private let storage = Mutex<[MeetingDiagnosticEvent]>([])

    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        storage.withLock { $0.append(event) }
    }

    var events: [MeetingDiagnosticEvent] { storage.withLock { $0 } }
}

enum LibrarySample {
    static func turn(
        _ number: Int, _ speaker: MeetingSpeakerLabel = .me, start: TimeInterval? = nil,
        text: String? = nil, echo: Bool = false
    ) -> MeetingTurn {
        let begin = start ?? Double(number) * 10
        return MeetingTurn(
            id: MeetingTurnID(number), track: speaker == .me ? .me : .them, speaker: speaker,
            start: begin, end: begin + 5, text: text ?? "turn \(number) words", isEcho: echo)
    }

    /// A fixed meeting date: 2026-11-23 10:15:00 UTC.
    static let startDate = Date(timeIntervalSince1970: 1_795_428_900)
}
