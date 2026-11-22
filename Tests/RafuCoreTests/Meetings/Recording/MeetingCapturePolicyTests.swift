import Foundation
import Synchronization
import Testing

@testable import RafuCore

/// Keeps every diagnostic event, for assertions.
final class CaptureTestDiagnostics: MeetingDiagnosticsRecording {
    private let events = Mutex<[MeetingDiagnosticEvent]>([])

    func record(_ event: MeetingDiagnosticEvent, meeting: MeetingID?) {
        events.withLock { $0.append(event) }
    }

    var recorded: [MeetingDiagnosticEvent] { events.withLock { $0 } }
}

@Suite("Meeting clock and capture policies")
struct MeetingCapturePolicyTests {
    // MARK: Clock

    @Test("The clock gives seconds from host times, on both timebases")
    func clockFromHostTimes() {
        let nanos = MeetingClock(startHostTime: 5_000_000_000, timebase: .nanoseconds)
        #expect(nanos.seconds(atHostTime: 5_000_000_000) == 0)
        #expect(abs(nanos.seconds(atHostTime: 17_650_000_000) - 12.65) < 1e-9)
        #expect(abs(nanos.seconds(atHostTime: 4_900_000_000) + 0.1) < 1e-9)

        // Apple silicon: 125/3 nanoseconds per tick (24 MHz).
        let silicon = MeetingHostTimebase(numerator: 125, denominator: 3)
        let clock = MeetingClock(startHostTime: 1_000, timebase: silicon)
        let me = clock.hostTime(atSeconds: 0.16)
        let them = clock.hostTime(atSeconds: 12.81)
        let gap = clock.seconds(atHostTime: them) - clock.seconds(atHostTime: me)
        #expect(abs(gap - 12.65) < 1e-6)
    }

    @Test("Recorded seconds leave out paused spans; gaps stay in")
    func recordedSeconds() {
        let facts = MeetingRecordingFacts(
            meeting: MeetingID(), startDate: Date(), outputWasSpeakers: true,
            spans: [
                MeetingRecordingSpan(kind: .paused, start: 10, end: 25),
                MeetingRecordingSpan(kind: .gap(.them), start: 30, end: 32),
            ], endTime: 60)
        #expect(facts.recordedSeconds == 45)
    }

    // MARK: Microphone policy

    private static let builtIn = MeetingInputDevice(
        objectID: 1, uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone",
        transportType: MeetingTransportType.builtIn)
    private static let airPods = MeetingInputDevice(
        objectID: 2, uid: "AA-BB:input", name: "AirPods Pro",
        transportType: MeetingTransportType.bluetooth)
    private static let usb = MeetingInputDevice(
        objectID: 3, uid: "usb-mic", name: "USB Microphone", transportType: MeetingTransportType.usb
    )

    @Test(
        "The Automatic microphone rule",
        arguments: [
            // (choice, default, inputs, expected device id, kind, reason)
            (
                MeetingMicrophoneChoice.automatic, airPods, [builtIn, airPods], UInt32(1),
                MeetingMicrophoneChoiceKind.automatic,
                MeetingMicrophoneChoiceReason.builtInOverCallHeadset
            ),
            (.automatic, builtIn, [builtIn, airPods], 1, .automatic, .systemDefault),
            (.automatic, usb, [builtIn, usb], 3, .automatic, .systemDefault),
            // A Mac with no built-in microphone keeps the headset.
            (.automatic, airPods, [airPods], 2, .automatic, .systemDefault),
            (.systemDefault, airPods, [builtIn, airPods], 2, .systemDefault, .systemDefault),
            (.device(uid: "usb-mic"), airPods, [builtIn, airPods, usb], 3, .named, .userSelected),
            (.device(uid: "gone"), airPods, [builtIn, airPods], 1, .named, .namedDeviceMissing),
        ]
            as [(
                MeetingMicrophoneChoice, MeetingInputDevice, [MeetingInputDevice], UInt32,
                MeetingMicrophoneChoiceKind, MeetingMicrophoneChoiceReason
            )])
    func microphonePolicy(
        row: (
            MeetingMicrophoneChoice, MeetingInputDevice, [MeetingInputDevice], UInt32,
            MeetingMicrophoneChoiceKind, MeetingMicrophoneChoiceReason
        )
    ) {
        let result = MeetingMicrophonePolicy.resolve(
            choice: row.0, defaultInput: row.1, inputs: row.2)
        #expect(result.device?.objectID == row.3)
        #expect(result.kind == row.4)
        #expect(result.reason == row.5)
    }

    @Test("No default input falls back to the built-in microphone")
    func noDefaultInput() {
        let result = MeetingMicrophonePolicy.resolve(
            choice: .automatic, defaultInput: nil, inputs: [Self.airPods, Self.builtIn])
        #expect(result.device == Self.builtIn)
        #expect(
            MeetingMicrophonePolicy.resolve(
                choice: .automatic, defaultInput: nil, inputs: []
            ).device == nil)
        #expect(
            MeetingMicrophonePolicy.resolve(
                choice: .systemDefault, defaultInput: Self.airPods, inputs: [Self.airPods]
            ).usesHeadsetMicrophone)
    }

    // MARK: Rate rule

    @Test("Tap says 48000, device says 24000: 24000 is used and the correction is recorded")
    func rateRule() {
        let diagnostics = CaptureTestDiagnostics()
        let meeting = MeetingID()
        let format = MeetingTapFormat(
            sampleRate: 48_000, channelCount: 2, bitsPerChannel: 32, isInterleaved: true)
        let result = MeetingSampleRatePolicy.resolve(
            tapFormat: format, deviceRate: 24_000, diagnostics: diagnostics, meeting: meeting)
        #expect(result.rate == 24_000)
        #expect(result.corrected)
        #expect(diagnostics.recorded.contains(.sampleRateCorrected(from: 48_000, to: 24_000)))
        #expect(diagnostics.recorded.contains(.tapFormat(format)))
        #expect(diagnostics.recorded.contains(.aggregateDeviceRate(nominalSampleRate: 24_000)))

        let same = CaptureTestDiagnostics()
        let unchanged = MeetingSampleRatePolicy.resolve(
            tapFormat: format, deviceRate: 48_000, diagnostics: same, meeting: meeting)
        #expect(unchanged.rate == 48_000 && !unchanged.corrected)
        #expect(
            !same.recorded.contains { if case .sampleRateCorrected = $0 { true } else { false } })

        // No readable device rate keeps the tap rate.
        #expect(
            MeetingSampleRatePolicy.effectiveRate(tapRate: 48_000, deviceRate: nil).rate == 48_000)
        #expect(
            MeetingSampleRatePolicy.effectiveRate(tapRate: 48_000, deviceRate: 0).rate == 48_000)
    }

    // MARK: Health

    @Test("No microphone buffers for 5 s is a finding, reported once")
    func microphoneNoBuffers() {
        var monitor = MeetingTrackHealthMonitor(track: .me, startedAt: 100)
        #expect(monitor.evaluate(at: 104.9, othersPlaying: false) == nil)
        #expect(monitor.evaluate(at: 105, othersPlaying: false) == .noBuffers)
        #expect(monitor.evaluate(at: 106, othersPlaying: false) == nil)
        monitor.noteBuffer(at: 106, silent: false)
        #expect(monitor.evaluate(at: 110.9, othersPlaying: false) == nil)
        #expect(monitor.evaluate(at: 111, othersPlaying: false) == .noBuffers)
    }

    @Test("No Them buffers while nothing plays is not a problem")
    func themQuietIsFine() {
        var monitor = MeetingTrackHealthMonitor(track: .them, startedAt: 0)
        for second in stride(from: 0.0, through: 60, by: 1) {
            #expect(monitor.evaluate(at: second, othersPlaying: false) == nil)
        }
    }

    @Test("No Them buffers for 5 s while another app plays is a finding")
    func themNoBuffersWhilePlaying() {
        var monitor = MeetingTrackHealthMonitor(track: .them, startedAt: 0)
        #expect(monitor.evaluate(at: 20, othersPlaying: true) == nil)
        #expect(monitor.evaluate(at: 24.9, othersPlaying: true) == nil)
        #expect(monitor.evaluate(at: 25, othersPlaying: true) == .noBuffers)
    }

    @Test("Exact silence while playing is a finding only before the first real sound")
    func themSilenceWhilePlaying() {
        var denied = MeetingTrackHealthMonitor(track: .them, startedAt: 0)
        #expect(denied.evaluate(at: 1, othersPlaying: true) == nil)
        for time in stride(from: 1.0, through: 6, by: 0.5) {
            denied.noteBuffer(at: time, silent: true)
        }
        #expect(denied.evaluate(at: 6, othersPlaying: true) == .silentWhilePlaying)

        var quietCall = MeetingTrackHealthMonitor(track: .them, startedAt: 0)
        _ = quietCall.evaluate(at: 1, othersPlaying: true)
        quietCall.noteBuffer(at: 1, silent: false)
        for time in stride(from: 1.5, through: 30, by: 0.5) {
            quietCall.noteBuffer(at: time, silent: true)
        }
        #expect(quietCall.hasHeardSound)
        #expect(quietCall.evaluate(at: 30, othersPlaying: true) == nil)
    }

    @Test("A restart waits the full limit again")
    func restartResetsTheLimit() {
        var monitor = MeetingTrackHealthMonitor(track: .me, startedAt: 0)
        monitor.noteBuffer(at: 1, silent: false)
        monitor.noteRestart(at: 10)
        #expect(monitor.evaluate(at: 14, othersPlaying: false) == nil)
        #expect(monitor.evaluate(at: 15, othersPlaying: false) == .noBuffers)
    }

    @Test("Block levels: silence, full scale and half scale")
    func blockLevels() {
        let silent = [Int16](repeating: 0, count: 160)
        let silence = silent.withUnsafeBufferPointer { MeetingBlockLevels.measure($0) }
        #expect(silence.isDigitalSilence)
        #expect(silence.peakDBFS == MeetingBlockLevels.floorDBFS)
        let loud = [Int16](repeating: 16_384, count: 160)
        let half = loud.withUnsafeBufferPointer { MeetingBlockLevels.measure($0) }
        #expect(!half.isDigitalSilence)
        #expect(abs(half.peakDBFS - (-6.02)) < 0.01)
        #expect(abs(half.meanDBFS - (-6.02)) < 0.01)
    }

    @Test("Permission problems name the pane to open")
    func settingsPanes() {
        #expect(
            MeetingCaptureProblem.missingMicrophonePermission.settingsPaneURL?.absoluteString
                .hasSuffix("Privacy_Microphone") == true)
        #expect(MeetingCaptureProblem.missingSystemAudioPermission.settingsPaneURL != nil)
        #expect(MeetingCaptureProblem.diskFull.settingsPaneURL == nil)
        for problem in MeetingCaptureProblem.allCases { #expect(!problem.message.isEmpty) }
    }
}
