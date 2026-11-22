import Foundation
import Testing

@testable import RafuCore

@Suite("Meeting recorder state machine")
struct MeetingRecorderMachineTests {
    private static let meeting = MeetingID()

    private typealias Row = (MeetingRecorderPhase, MeetingRecorderEffect)

    /// The expected result of each command in each phase, written out by
    /// hand (not derived from the machine). Command order: start, pause,
    /// resume, stop, startSucceeded, startFailed(mic), stopFinished,
    /// fault(diskFull), dismissProblem.
    private static func expected(for phase: MeetingRecorderPhase) -> [Row] {
        let m = meeting
        let same: Row = (phase, .none)
        switch phase {
        case .idle:
            return [
                (.starting(stopRequested: false), .beginStart), same, same, same, same, same,
                same, same, same,
            ]
        case .starting(false):
            return [
                same, same, same, (.starting(stopRequested: true), .none), (.recording(m), .none),
                (.problem(.missingMicrophonePermission), .none), same, same, same,
            ]
        case .starting(true):
            return [
                same, same, same, same, (.idle, .abandonStart(m)), (.idle, .none), same, same,
                same,
            ]
        case .recording:
            return [
                same, (.paused(m), .pauseCapture(m)), same,
                (.stopping(m, problem: nil), .beginStop(m)), same, same, same,
                (.stopping(m, problem: .diskFull), .beginStop(m)), same,
            ]
        case .paused:
            return [
                same, same, (.recording(m), .resumeCapture(m)),
                (.stopping(m, problem: nil), .beginStop(m)), same, same, same,
                (.stopping(m, problem: .diskFull), .beginStop(m)), same,
            ]
        case .stopping(_, nil):
            return [
                same, same, same, same, same, same, (.idle, .none),
                (.stopping(m, problem: .diskFull), .none), same,
            ]
        case .stopping(_, let problem?):
            return [
                same, same, same, same, same, same, (.problem(problem), .none), same, same,
            ]
        case .problem:
            return [
                (.starting(stopRequested: false), .beginStart), same, same, same, same, same,
                same, same, (.idle, .none),
            ]
        }
    }

    @Test("Each command in each phase has the defined result")
    func transitionTable() {
        let commands = MeetingRecorderCommand.samples(meeting: Self.meeting)
        let phases = MeetingRecorderPhase.samples(meeting: Self.meeting)
        #expect(commands.count == 9)
        #expect(phases.count == 8)
        for phase in phases {
            let rows = Self.expected(for: phase)
            for (command, row) in zip(commands, rows) {
                let result = MeetingRecorderMachine.transition(from: phase, on: command)
                #expect(result.phase == row.0, "\(phase) + \(command)")
                #expect(result.effect == row.1, "\(phase) + \(command)")
            }
        }
    }

    @Test("Two Starts give one session")
    func twoStarts() {
        let first = MeetingRecorderMachine.transition(from: .idle, on: .start)
        #expect(first.effect == .beginStart)
        let second = MeetingRecorderMachine.transition(from: first.phase, on: .start)
        #expect(second.effect == .none)
        let recording = MeetingRecorderMachine.transition(
            from: second.phase, on: .startSucceeded(Self.meeting))
        let third = MeetingRecorderMachine.transition(from: recording.phase, on: .start)
        #expect(third.effect == .none)
        #expect(third.phase == .recording(Self.meeting))
    }

    @Test("Stop during starting ends cleanly in idle")
    func stopDuringStarting() {
        var phase = MeetingRecorderMachine.transition(from: .idle, on: .start).phase
        phase = MeetingRecorderMachine.transition(from: phase, on: .stop).phase
        #expect(phase.state == .starting)
        let done = MeetingRecorderMachine.transition(from: phase, on: .startSucceeded(Self.meeting))
        #expect(done.phase == .idle)
        #expect(done.effect == .abandonStart(Self.meeting))
    }

    @Test("The public state hides the internal flags")
    func publicState() {
        #expect(MeetingRecorderPhase.starting(stopRequested: true).state == .starting)
        #expect(
            MeetingRecorderPhase.stopping(Self.meeting, problem: .diskFull).state
                == .stopping(Self.meeting))
    }
}
