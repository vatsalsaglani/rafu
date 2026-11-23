import Foundation
import Testing

@testable import RafuCore

@Suite("Hidden meeting agent: streaming, probe and summary contracts")
struct MeetingAgentStreamingContractTests {
    @Test("The automatic summary is on when the Settings key is missing")
    func autoSummaryDefault() throws {
        let name = "rafu-auto-summary-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(MeetingAutoSummaryPreference.isOn(defaults))
        defaults.set(false, forKey: MeetingAutoSummaryPreference.key)
        #expect(!MeetingAutoSummaryPreference.isOn(defaults))
        defaults.set(true, forKey: MeetingAutoSummaryPreference.key)
        #expect(MeetingAutoSummaryPreference.isOn(defaults))
    }

    @Test("Each probe result has the words of the interface")
    func probeMessages() {
        #expect(MeetingAgentProbeResult.notInstalled.message == "not installed")
        #expect(MeetingAgentProbeResult.notSignedIn.message == "not signed in")
        #expect(
            MeetingAgentProbeResult.unsupportedVersion(found: "9.9.9").message
                == "this version is not supported")
        #expect(MeetingAgentProbeResult.ready.isReady)
        for failure in [
            MeetingAgentProbeFailure.versionUnreadable, .launchFailed, .timedOut, .noAnswer,
            .settingNotKnown, .toolListUnreadable, .toolEvent, .wroteFiles,
        ] {
            #expect(!failure.message.isEmpty)
            #expect(MeetingAgentProbeResult.failed(reason: failure).message == failure.message)
        }
    }

    @Test("A probe result and the notes survive a JSON round trip")
    func codableRoundTrip() throws {
        let results: [MeetingAgentProbeResult] = [
            .ready, .notInstalled, .notSignedIn, .unsupportedVersion(found: "0.172.0"),
            .failed(reason: .wroteFiles),
        ]
        let data = try JSONEncoder().encode(results)
        #expect(try JSONDecoder().decode([MeetingAgentProbeResult].self, from: data) == results)

        let notes = MeetingSummaryNotes(
            title: "Launch plan", summaryMarkdown: "Ship on March 14 [t2].",
            decisions: [MeetingSummaryItem(text: "Ship", citations: [MeetingTurnID(2)])],
            actionItems: [MeetingSummaryItem(text: "Notes", owner: "Priya")],
            citations: [MeetingTurnID(2)], cli: .codex, date: Date(timeIntervalSince1970: 10),
            textRevision: 3)
        let decoded = try JSONDecoder().decode(
            MeetingSummaryNotes.self, from: try JSONEncoder().encode(notes))
        #expect(decoded == notes)
        #expect(decoded.schema == MeetingSummaryNotes.currentSchema)
    }

    @Test("A conversation line from before the text revision still decodes")
    func oldConversationLine() throws {
        let line =
            #"{"id":"6F1C3C5A-2B7E-4C4B-9C1D-1B2C3D4E5F60","date":1.5,"role":"answer","text":"x","citations":[]}"#
        let entry = try JSONDecoder().decode(MeetingConversationEntry.self, from: Data(line.utf8))
        #expect(entry.textRevision == nil)
    }
}
