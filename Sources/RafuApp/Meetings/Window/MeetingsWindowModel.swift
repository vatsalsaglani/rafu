import Foundation
import Observation
import RafuCore

/// The list state of the Meetings window: meeting summaries only, never a
/// transcript. Owned by the window view in private `@State`.
@MainActor
@Observable
final class MeetingsWindowModel {
    enum LoadState: Equatable {
        case loading
        case loaded
        /// "The meetings could not be read."
        case failed
    }

    private(set) var sections: [MeetingsListSection] = []
    private(set) var loadState: LoadState = .loading
    /// Goes up when the user presses "Try again" after a failed read.
    private(set) var retryToken = 0

    @ObservationIgnored private var summaries: [MeetingID: MeetingSummaryRecord] = [:]

    var isEmpty: Bool { sections.isEmpty }

    func summary(for meeting: MeetingID?) -> MeetingSummaryRecord? {
        meeting.flatMap { summaries[$0] }
    }

    func retry() { retryToken += 1 }

    /// Reads the list from the store. Returns the listed ids, or nil when
    /// the read failed. Nothing with text is recorded on a failure.
    @discardableResult
    func reload(
        from store: (any MeetingStoring)?, now: Date = Date(), calendar: Calendar = .current,
        locale: Locale = .current
    ) async -> Set<MeetingID>? {
        guard let store else {
            apply([], now: now, calendar: calendar, locale: locale)
            return []
        }
        do {
            let list = try await store.list()
            apply(list, now: now, calendar: calendar, locale: locale)
            return Set(list.map(\.id))
        } catch is CancellationError {
            return nil
        } catch {
            loadState = .failed
            return nil
        }
    }

    /// Applies a list, for the reload and for tests.
    func apply(
        _ list: [MeetingSummaryRecord], now: Date, calendar: Calendar, locale: Locale
    ) {
        summaries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        sections = MeetingsWindowPresentation.sections(
            list, now: now, calendar: calendar, locale: locale)
        loadState = .loaded
    }

    /// Renames one meeting. On a version conflict it reads the summary
    /// again and tries one more time. Returns true on success.
    @discardableResult
    func rename(
        _ meeting: MeetingID, to title: String, store: (any MeetingStoring)?,
        session: MeetingsSessionModel
    ) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, !trimmed.isEmpty else { return false }
        do {
            let version = try await currentVersion(of: meeting, store: store)
            do {
                try await store.rename(meeting, title: trimmed, expectedVersion: version)
            } catch is MeetingVersionConflict {
                let fresh = try await currentVersion(of: meeting, store: store, reread: true)
                try await store.rename(meeting, title: trimmed, expectedVersion: fresh)
            }
            session.noteLibraryChanged()
            return true
        } catch {
            return false
        }
    }

    private func currentVersion(
        of meeting: MeetingID, store: any MeetingStoring, reread: Bool = false
    ) async throws -> Int {
        if !reread, let known = summaries[meeting] { return known.version }
        guard let summary = try await store.summary(of: meeting) else {
            throw MeetingGone()
        }
        return summary.version
    }

    private struct MeetingGone: Error {}
}

/// The actions of the Meetings window. Each one only calls the session
/// model, so a test records the calls through `session.handlers`.
@MainActor
struct MeetingsWindowCommands {
    let session: MeetingsSessionModel

    /// Starts a recording when one can start. The start view shows, so a
    /// start failure is seen. Returns false when Record is not active.
    @discardableResult
    func record() -> Bool {
        guard session.canStartRecording else { return false }
        session.windowSelection = nil
        session.startFailure = nil
        session.startRecording()
        return true
    }

    func pause() { session.pause() }
    func resume() { session.resume() }
    func stop() { session.stop() }

    func cancelProcessing(_ meeting: MeetingID) { session.cancelProcessing(meeting) }
    func retryProcessing(_ meeting: MeetingID) { session.retryProcessing(meeting) }

    /// The live meeting cannot be deleted; Stop it first.
    func canDelete(_ meeting: MeetingID) -> Bool { meeting != session.liveMeeting }

    func delete(_ meeting: MeetingID) {
        guard canDelete(meeting) else { return }
        if session.windowSelection == meeting { session.windowSelection = nil }
        session.deleteMeeting(meeting)
    }

    func dismissBanner() {
        session.dismissProblem()
        session.startFailure = nil
    }
}

/// The microphone that the next recording uses, before a recording.
nonisolated struct MeetingsMicrophoneSummary: Hashable, Sendable {
    var name: String?
    /// A Bluetooth headset microphone (poor text).
    var isHeadset: Bool
}

/// Reads the next microphone. A test uses a fake; the app reads Core Audio.
nonisolated protocol MeetingsMicrophoneReading: Sendable {
    func read() async -> MeetingsMicrophoneSummary
}

/// Reads device facts off the main actor. It opens no device and asks for
/// no permission.
nonisolated struct MeetingsCoreAudioMicrophoneReader: MeetingsMicrophoneReading {
    @concurrent
    func read() async -> MeetingsMicrophoneSummary {
        let audio = MeetingCoreAudio(diagnostics: NoopMeetingDiagnostics(), meeting: nil)
        let inputs = audio.inputDevices()
        let defaultInput = audio.defaultDevice(input: true).flatMap { audio.inputDevice($0) }
        let resolution = MeetingMicrophonePolicy.resolve(
            choice: UserDefaultsMeetingPreferences().microphoneChoice(),
            defaultInput: defaultInput, inputs: inputs)
        return MeetingsMicrophoneSummary(
            name: resolution.device?.name, isHeadset: resolution.usesHeadsetMicrophone)
    }
}
