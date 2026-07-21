import Foundation

/// Zero-config "the agent finished / wants input" detection
/// (terminal-manager.md T-E follow-up): agent TUIs (claude, codex, cline)
/// paint CONSTANTLY while working — spinners, streamed tokens, redraws —
/// and go silent the moment they wait for input. A sustained burst of
/// output followed by silence on an UNFOCUSED session is therefore the
/// universal completion signal, needing no per-CLI configuration, no
/// escape-sequence support, and no output parsing (timing and byte counts
/// only — content is never inspected).
///
/// Explicit escapes (BEL, OSC 9/777) still take the fast path; this is the
/// fallback that makes attention work out of the box.
///
/// Tuning: `minimumBusySeconds`/`minimumBusyBytes` exist so a short burst
/// (ls, a prompt repaint after reveal) never counts as "was working";
/// `quietSeconds` is how long silence must last before we call it done.
nonisolated struct TerminalQuiescencePolicy: Equatable, Sendable {
    var minimumBusySeconds: TimeInterval = 4
    var minimumBusyBytes: Int = 2_048
    var quietSeconds: TimeInterval = 2.5

    nonisolated enum State: Equatable, Sendable {
        case idle
        /// Output arriving; tracking the burst.
        case busy(since: Date, bytes: Int, lastOutput: Date)
    }

    /// Feed one activity sample. Pure: same inputs, same outputs.
    func advance(_ state: State, bytes: Int, at now: Date) -> State {
        switch state {
        case .idle:
            return .busy(since: now, bytes: bytes, lastOutput: now)
        case .busy(let since, let total, _):
            return .busy(since: since, bytes: total + bytes, lastOutput: now)
        }
    }

    /// Whether the burst has ended and QUALIFIED as real work — checked on
    /// a timer tick. Returns the reset state alongside the verdict so the
    /// caller can never observe a fired-but-still-busy state.
    func checkQuiescence(_ state: State, at now: Date) -> (fired: Bool, state: State) {
        guard case .busy(let since, let bytes, let lastOutput) = state else {
            return (false, state)
        }
        guard now.timeIntervalSince(lastOutput) >= quietSeconds else { return (false, state) }
        let qualified =
            lastOutput.timeIntervalSince(since) >= minimumBusySeconds
            && bytes >= minimumBusyBytes
        return (qualified, .idle)
    }
}
