import Foundation
import RafuCore
import SwiftUI
import Testing

@testable import RafuApp

@Suite("Meetings status surfaces")
struct MeetingsStatusPolicyTests {
    private static let meeting = MeetingID()

    private static func input(
        _ state: MeetingRecorderState, elapsed: TimeInterval = 767,
        processing: [MeetingID: MeetingsProcessingStep] = [:],
        warnings: [MeetingsLiveWarning] = [], canStart: Bool = true, canOpen: Bool = true,
        floatingBar: Bool = false
    ) -> MeetingsStatusInput {
        MeetingsStatusInput(
            recorderState: state, elapsed: elapsed, processing: processing, warnings: warnings,
            canStartRecording: canStart, canOpenWindow: canOpen, floatingBarEnabled: floatingBar)
    }

    private static let processingInput = input(
        .idle, processing: [MeetingID(): .text(track: .me, fraction: 0.4)])

    // MARK: Menu bar item

    @Test("The menu bar item has a symbol or a dot, a time and a label for each state")
    func statusItemContent() {
        let idle = MeetingsStatusPolicy.statusItem(Self.input(.idle))
        #expect(
            idle
                == .init(
                    symbolName: "waveform", title: "",
                    accessibilityLabel: "Meetings: ready to record"))

        let recording = MeetingsStatusPolicy.statusItem(Self.input(.recording(Self.meeting)))
        #expect(recording.symbolName == nil)
        #expect(recording.title == "● 12:47")
        #expect(recording.accessibilityLabel == "Meetings: recording, 12:47")

        let paused = MeetingsStatusPolicy.statusItem(Self.input(.paused(Self.meeting)))
        #expect(paused.symbolName == "pause.fill")
        #expect(paused.title == "12:47")
        #expect(paused.accessibilityLabel == "Meetings: recording paused, 12:47")

        let processing = MeetingsStatusPolicy.statusItem(Self.processingInput)
        #expect(processing.symbolName == "circle.dashed")
        #expect(processing.title == "")
        #expect(processing.accessibilityLabel == "Meetings: processing")

        // Ready after a meeting became ready: the same as idle.
        let ready = MeetingsStatusPolicy.statusItem(
            Self.input(.idle, processing: [:]))
        #expect(ready == idle)

        // A failed step alone is not processing.
        let failed = Self.input(.idle, processing: [MeetingID(): .failed(reasonCode: "x")])
        #expect(MeetingsStatusPolicy.phase(failed) == .idle)
    }

    @Test("Starting a recording already shows the dot")
    func startingShowsIndicator() {
        let starting = MeetingsStatusPolicy.statusItem(Self.input(.starting, elapsed: 0))
        #expect(starting.title.hasPrefix("●"))
        #expect(MeetingsStatusPolicy.phase(Self.input(.starting)).isCapturing)
    }

    // MARK: Menu

    private static func actions(_ items: [MeetingsStatusMenuItem]) -> [MeetingsStatusAction] {
        items.compactMap(\.action)
    }

    private static func item(
        _ action: MeetingsStatusAction, in items: [MeetingsStatusMenuItem]
    ) -> MeetingsStatusMenuItem? {
        items.first { $0.action == action }
    }

    @Test("Idle menu: Start Recording follows canStartRecording")
    func idleMenu() throws {
        let items = MeetingsStatusPolicy.menu(Self.input(.idle))
        #expect(items.first == .info("Ready to record"))
        #expect(Self.actions(items) == [.startRecording, .openMeetings, .toggleFloatingBar])
        #expect(try #require(Self.item(.startRecording, in: items)).isEnabled)
        #expect(try #require(Self.item(.startRecording, in: items)).title == "Start Recording")

        let blocked = MeetingsStatusPolicy.menu(Self.input(.idle, canStart: false))
        #expect(try #require(Self.item(.startRecording, in: blocked)).isEnabled == false)
    }

    @Test("Recording menu has Pause and Stop; paused has Resume and Stop")
    func recordingAndPausedMenus() {
        let recording = MeetingsStatusPolicy.menu(Self.input(.recording(Self.meeting)))
        #expect(recording.first == .info("Recording 12:47"))
        #expect(Self.actions(recording) == [.pause, .stop, .openMeetings, .toggleFloatingBar])
        let allEnabled = recording.filter { $0.action != nil }.allSatisfy(\.isEnabled)
        #expect(allEnabled)

        let paused = MeetingsStatusPolicy.menu(Self.input(.paused(Self.meeting)))
        #expect(paused.first == .info("Paused 12:47"))
        #expect(Self.actions(paused) == [.resume, .stop, .openMeetings, .toggleFloatingBar])
    }

    @Test("Processing menu shows the step")
    func processingMenu() {
        let items = MeetingsStatusPolicy.menu(Self.processingInput)
        #expect(items.first == .info("Processing: Writing the text (Me) 40%"))
        let two = Self.input(
            .idle, processing: [MeetingID(): .speakers, MeetingID(): .finishing])
        #expect(MeetingsStatusPolicy.menu(two).first == .info("Processing: 2 meetings"))
    }

    @Test("A warning adds its line; a failed step adds a line")
    func warningLines() {
        let items = MeetingsStatusPolicy.menu(
            Self.input(
                .recording(Self.meeting), processing: [MeetingID(): .failed(reasonCode: "x")],
                warnings: [.themNoSound]))
        #expect(items.contains(.info(MeetingsLiveWarning.themNoSound.message)))
        #expect(items.contains(.info(MeetingsStatusPolicy.processingStoppedNote)))
        #expect(items.filter { !$0.isEnabled && !$0.isSeparator }.count == 3)
    }

    @Test("Open Meetings follows canOpen; the floating bar item shows its check mark")
    func openAndFloatingBarItems() throws {
        let closed = MeetingsStatusPolicy.menu(Self.input(.idle, canOpen: false))
        #expect(try #require(Self.item(.openMeetings, in: closed)).isEnabled == false)
        #expect(try #require(Self.item(.toggleFloatingBar, in: closed)).isChecked == false)
        let open = MeetingsStatusPolicy.menu(Self.input(.idle, canOpen: true, floatingBar: true))
        #expect(try #require(Self.item(.openMeetings, in: open)).isEnabled)
        let toggle = try #require(Self.item(.toggleFloatingBar, in: open))
        #expect(toggle.isChecked)
        #expect(toggle.title == "Show Floating Recording Bar")
    }

    @Test("A problem shows a stopped line with its reason and allows Record")
    func problemMenu() throws {
        let items = MeetingsStatusPolicy.menu(Self.input(.problem(.deviceLost)))
        #expect(items.first == .info("The recording stopped"))
        #expect(items.contains(.info(MeetingsStartFailure.problem(.deviceLost).message)))
        #expect(try #require(Self.item(.startRecording, in: items)).isEnabled)
    }

    // MARK: Floating bar

    @Test("The floating bar shows only for recording or paused with the setting on")
    func floatingBarVisibility() {
        let states: [MeetingRecorderState] = [
            .idle, .starting, .recording(Self.meeting), .paused(Self.meeting),
            .stopping(Self.meeting), .problem(.noBuffers),
        ]
        for state in states {
            let on = MeetingsStatusPolicy.showsFloatingBar(Self.input(state, floatingBar: true))
            let off = MeetingsStatusPolicy.showsFloatingBar(Self.input(state, floatingBar: false))
            #expect(!off)
            switch state {
            case .recording, .paused: #expect(on)
            default: #expect(!on)
            }
        }
    }

    @Test("The floating bar sits at the top centre, 60 points below the menu bar")
    func floatingBarOrigin() {
        let origin = MeetingsFloatingBarGeometry.origin(
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            size: CGSize(width: 200, height: 40))
        #expect(origin == CGPoint(x: 400, y: 700))
    }

    // MARK: Section

    @Test("The section has a shape, a word and a time; idle is empty")
    func sectionContent() {
        let idle = MeetingsStatusPolicy.section(Self.input(.idle))
        #expect(idle.isEmpty)
        #expect(idle.timeText == nil)

        let recording = MeetingsStatusPolicy.section(
            Self.input(.recording(Self.meeting), warnings: [.speakersEcho]))
        #expect(!recording.isEmpty)
        #expect(recording.word == "Recording")
        #expect(recording.symbolName == "record.circle.fill")
        #expect(recording.timeText == "12:47")
        #expect(recording.showsMeters)
        #expect(recording.warnings == [.speakersEcho])
        #expect(recording.buttons.map(\.action) == [.pause, .stop])

        let paused = MeetingsStatusPolicy.section(Self.input(.paused(Self.meeting)))
        #expect(paused.word == "Paused")
        #expect(paused.buttons.map(\.action) == [.resume, .stop])

        let processing = MeetingsStatusPolicy.section(Self.processingInput)
        #expect(processing.word == "Processing")
        #expect(processing.notes == ["Writing the text (Me) 40%"])
        #expect(!processing.showsMeters)
    }

    // MARK: Privacy

    @MainActor
    @Test("No surface text contains the meeting title")
    func noTitleInOutput() {
        let marker = "ZebraMarkerTitle"
        let session = MeetingsSessionModel()
        session.liveTitle = marker
        session.isDriverInstalled = true
        session.warnings = MeetingsLiveWarning.allCases
        session.processing = [MeetingID(): .speakers, MeetingID(): .failed(reasonCode: "x")]
        let states: [MeetingRecorderState] = [
            .idle, .starting, .recording(Self.meeting), .paused(Self.meeting),
            .stopping(Self.meeting), .problem(.diskFull),
        ]
        for state in states {
            session.recorderState = state
            let input = MeetingsStatusActions.input(
                session: session, canOpenWindow: true, floatingBarEnabled: true)
            var texts: [String] = []
            let item = MeetingsStatusPolicy.statusItem(input)
            texts += [item.title, item.accessibilityLabel]
            texts += MeetingsStatusPolicy.menu(input).map(\.title)
            let section = MeetingsStatusPolicy.section(input)
            texts += [section.word, section.timeText ?? ""] + section.notes
            texts += section.buttons.map(\.title)
            texts += section.warnings.map(\.message)
            #expect(!texts.contains { $0.contains(marker) })
        }
    }

    // MARK: Actions and registration

    @MainActor
    @Test("Each action calls its handler one time")
    func actionsCallHandlers() {
        let session = MeetingsSessionModel()
        session.recorderState = .recording(Self.meeting)
        var calls: [String] = []
        session.handlers.start = { calls.append("start:\($0 ?? "nil")") }
        session.handlers.pause = { calls.append("pause") }
        session.handlers.resume = { calls.append("resume") }
        session.handlers.stop = { calls.append("stop") }
        var opened: [MeetingID?] = []
        var toggles = 0
        for action in MeetingsStatusAction.allCases {
            MeetingsStatusActions.perform(
                action, session: session, openWindow: { opened.append($0) },
                toggleFloatingBar: { toggles += 1 })
        }
        #expect(calls == ["start:nil", "pause", "resume", "stop"])
        #expect(opened == [Self.meeting])
        #expect(toggles == 1)
    }

    @MainActor
    @Test("The floating bar setting is off by default")
    func floatingBarSettingDefault() throws {
        let suite = TestDefaultsSuite.name("dev.rafu.tests.meetings-status")
        defer { TestDefaultsSuite.remove(suite) }
        let defaults = try #require(UserDefaults(suiteName: suite))
        let setting = MeetingsFloatingBarSetting(defaults: defaults)
        #expect(!setting.isEnabled)
        setting.isEnabled = true
        #expect(defaults.bool(forKey: "meetings.companion.floatingBar"))
    }

    @MainActor
    @Test("Registration on a test feature adds the section and makes no menu bar item")
    func registrationOnTestFeature() {
        let feature = MeetingsFeature(availability: .available)
        feature.registerCompanionParts()
        #expect(feature.companionSection != nil)
        #expect(feature.registeredKinds == [.companionSection])
        #expect(!MeetingsStatusSurfaces.isInstalled)
        #expect(MeetingsStatusSurfaces.statusItem == nil)
        #expect(MeetingsStatusSurfaces.floatingBar == nil)
    }
}
