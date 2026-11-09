import Foundation
import Observation
import RafuCore

/// What `agent_configure` reads from and does to one terminal node. The live
/// value reads the node's controller and types through the board's queued
/// lines (`CanvasTerminalStarter`); a test injects its own closures.
@MainActor
struct CanvasAgentConfigureTerminal {
    /// The pane is live (a shell process runs).
    var isLive: () -> Bool
    /// The hook state of the agent session in the node; nil without a
    /// matched, current session (a stale `working` session counts as none).
    var hookState: () -> AgentSessionState?
    /// The conversation id to resume: the hook session id, else the Codex
    /// bridge thread id.
    var sessionID: (CanvasAgentConfigureAgent) -> String?
    var secondsSinceOutput: () -> TimeInterval?
    /// The agent CLI in front of the shell, from the process sample (no hooks).
    var agentInFront: () -> CanvasAgentConfigureAgent?
    /// The newest viewport lines, raw. Scrubbed before anything leaves Rafu.
    var viewport: () -> [String]?
    /// Queues one line and asks the node to type it. False when the node's
    /// queue is full or its shell does not run.
    var type: (String) async throws -> Bool
    /// No queued line waits and no Return is owed.
    var isTypingDone: () -> Bool
    /// One wait step. Tests make it a yield.
    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
}

extension CanvasAgentConfigureTerminal {
    /// The node's first pane. Every closure finds the controller again, so a
    /// replaced controller is never used stale.
    static func live(card: CanvasCard, groupID: TerminalGroupID, caller: CanvasAgentCaller)
        -> CanvasAgentConfigureTerminal
    {
        let session = caller.session
        let board = caller.board
        let controller: @MainActor () -> WorkspaceTerminalController? = { [weak session] in
            guard let session,
                let id = session.terminal.terminalGroup(groupID)?.panes.first?.sessionID
            else { return nil }
            return session.terminal.sessions.first { $0.id == id }
        }
        let tracked: @MainActor () -> TrackedAgentSession? = {
            guard let controller = controller(),
                let session = AgentActivityStore.shared.trackedSession(for: controller),
                !session.isStale(at: Date())
            else { return nil }
            return session
        }
        return CanvasAgentConfigureTerminal(
            isLive: { [weak session] in
                session?.terminal.terminalGroup(groupID)?.panes.first?.status == .live
            },
            hookState: { tracked()?.state },
            sessionID: { agent in
                if let session = tracked(),
                    CanvasAgentConfigureAgent(hookProvider: session.provider) == agent
                {
                    return session.sessionID
                }
                guard agent == .codex, let controller = controller() else { return nil }
                return CanvasLiveBridge.shared.codexThreadID(controllerID: controller.id)
            },
            secondsSinceOutput: { controller()?.secondsSinceLastOutput },
            agentInFront: {
                switch controller()?.observedAgentProvider {
                case .claudeCode?: .claude
                case .codex?: .codex
                default: nil
                }
            },
            viewport: {
                controller()?.recentOutputLines(maxLines: CanvasAgentConfigureRunner.viewportLines)
            },
            type: { line in
                let report = try await CanvasAgentActions.start(card, line: line, caller: caller)
                return !report.queueFull && report.running
            },
            isTypingDone: { [weak board] in
                (board?.pendingTerminalLineCount(for: card.id) ?? 0) == 0
                    && controller()?.isReturnPending != true
            })
    }
}

extension CanvasAgentConfigureAgent {
    init?(hookProvider: AgentHookProvider) {
        switch hookProvider.cli {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        default: return nil
        }
    }
}

/// Runs the steps of one `CanvasAgentConfigurePlan`. Every wait is bounded and
/// counted in steps of `step`, so the bridge call stays inside its IPC timeout
/// and a test can replace the sleep.
@MainActor
enum CanvasAgentConfigureRunner {
    static let step: Duration = .milliseconds(100)
    static let viewportLines = 12
    /// Typing waits for the node's queued lines (the drain waits up to 2 s per
    /// line for a quiet terminal).
    static let typingSteps = 60
    /// The readback window after the last line: 2 s.
    static let readbackSteps = 20
    /// The agent must quit within 6 s of its exit line.
    static let exitSteps = 60
    /// The shell must be quiet this long before the resume line.
    static let shellQuietSeconds: TimeInterval = 1
    /// A resumed agent must be in front within 8 s.
    static let agentStartSteps = 80

    /// Tests replace the live terminal of a node for their own call tree.
    @TaskLocal static var terminalOverride:
        (@MainActor @Sendable (CanvasCard) -> CanvasAgentConfigureTerminal?)?

    static func terminal(card: CanvasCard, groupID: TerminalGroupID, caller: CanvasAgentCaller)
        -> CanvasAgentConfigureTerminal
    {
        if let override = terminalOverride, let terminal = override(card) { return terminal }
        return .live(card: card, groupID: groupID, caller: caller)
    }

    struct Outcome: Equatable {
        /// Every step ran. False: Rafu stopped before a later step.
        var completed: Bool
        var confirmed: Bool
        var readback: String?
        var message: String
    }

    static func run(
        _ plan: CanvasAgentConfigurePlan, request: CanvasAgentConfigureRequest,
        terminal: CanvasAgentConfigureTerminal, title: String
    ) async -> Outcome {
        let name = "\(plan.agent.displayName) in “\(CanvasAgentText.singleLine(title, limit: 40))”"
        var before = terminal.viewport() ?? []
        var readback: (confirmed: Bool, text: String)?
        for item in plan.steps {
            switch item {
            case .agentLine(let line):
                guard await type(line, terminal) else { return notTyped(name) }
            case .exitAgent(let line):
                guard await type(line, terminal) else { return notTyped(name) }
                _ = await wait(steps: typingSteps, terminal) { terminal.isTypingDone() }
                let back = await wait(steps: exitSteps, terminal) {
                    shellIsBack(terminal, agent: plan.agent)
                }
                guard back else {
                    return Outcome(
                        completed: false, confirmed: false, readback: nil,
                        message:
                            "\(name) did not quit within 6 seconds, so Rafu did not type the resume line. The agent may still run; ask the user to check the terminal. Do not retry."
                    )
                }
            case .shellCommand(let argv):
                guard let line = CanvasAgentShell.commandLine(argv) else {
                    return Outcome(
                        completed: false, confirmed: false, readback: nil,
                        message: "Rafu refused the resume line for \(name).")
                }
                guard await type(line, terminal) else { return notTyped(name) }
                _ = await wait(steps: typingSteps, terminal) { terminal.isTypingDone() }
            case .waitForAgent:
                let started = await wait(steps: agentStartSteps, terminal) {
                    terminal.agentInFront() == plan.agent
                }
                guard started else {
                    return Outcome(
                        completed: true, confirmed: false, readback: nil,
                        message:
                            "Rafu typed the resume line, but \(name) did not appear within 8 seconds. Ask the user to check the terminal. Do not retry."
                    )
                }
                before = terminal.viewport() ?? []
            case .readback(let matcher):
                _ = await wait(steps: typingSteps, terminal) { terminal.isTypingDone() }
                var after = terminal.viewport() ?? before
                var matched = matcher.matches(before: before, after: after)
                var remaining = readbackSteps
                while !matched, remaining > 0 {
                    remaining -= 1
                    do { try await terminal.sleep(step) } catch { break }
                    after = terminal.viewport() ?? after
                    matched = matcher.matches(before: before, after: after)
                }
                readback = (matched, matcher.readback(before: before, after: after))
            }
        }
        return Outcome(
            completed: true, confirmed: readback?.confirmed ?? false, readback: readback?.text,
            message: message(plan: plan, request: request, name: name, readback: readback))
    }

    private static func message(
        plan: CanvasAgentConfigurePlan, request: CanvasAgentConfigureRequest, name: String,
        readback: (confirmed: Bool, text: String)?
    ) -> String {
        var values: [String] = []
        if let model = request.model { values.append("model \(model)") }
        if let effort = request.effort { values.append("effort \(effort)") }
        if let mode = request.mode { values.append("mode \(mode)") }
        let change = values.joined(separator: ", ")
        switch (plan.strategy, readback?.confirmed) {
        case (.inPlace, true?):
            return "\(name) shows the change: \(change)."
        case (.inPlace, _):
            return
                "Rafu typed the change (\(change)) into \(name), but the terminal did not show it within 2 seconds. Tell the user it is not confirmed; readback has the newest lines. Do not retry."
        case (.resume, true?):
            return
                "\(name) quit and resumed the same conversation with \(change); its status shows the change."
        case (.resume, false?):
            return
                "\(name) quit and resumed the same conversation with \(change), but its status did not show the change within 2 seconds. Tell the user it is not confirmed. Do not retry."
        case (.resume, nil):
            return
                "\(name) quit and Rafu typed the resume line with \(change). Rafu does not read the change back after a resume; ask the user to check the terminal."
        }
    }

    private static func notTyped(_ name: String) -> Outcome {
        Outcome(
            completed: false, confirmed: false, readback: nil,
            message:
                "Rafu could not type into \(name): its shell is not running or too many lines wait. Do not retry."
        )
    }

    private static func type(_ line: String, _ terminal: CanvasAgentConfigureTerminal) async
        -> Bool
    {
        (try? await terminal.type(line)) ?? false
    }

    /// The shell is back in front: no agent sample, or the hook session
    /// ended, and the terminal has been quiet for `shellQuietSeconds`.
    private static func shellIsBack(
        _ terminal: CanvasAgentConfigureTerminal, agent: CanvasAgentConfigureAgent
    ) -> Bool {
        let gone = terminal.agentInFront() != agent || terminal.hookState() == .ended
        let quiet = (terminal.secondsSinceOutput() ?? .infinity) >= shellQuietSeconds
        return gone && quiet && terminal.isLive()
    }

    /// Checks `condition` up to `steps + 1` times, one `step` apart.
    private static func wait(
        steps: Int, _ terminal: CanvasAgentConfigureTerminal, until condition: () -> Bool
    ) async -> Bool {
        for index in 0...steps {
            if condition() { return true }
            guard index < steps else { break }
            do { try await terminal.sleep(step) } catch { return false }
        }
        return false
    }
}

/// One waiting change per node, run when the agent's turn ends. It watches
/// the node's hook state with Observation (`withObservationTracking`,
/// re-armed after each change); there is no timer. The change was already
/// confirmed by the user when it was queued.
@MainActor
final class CanvasAgentConfigureQueue {
    static let shared = CanvasAgentConfigureQueue()
    /// A change still waiting after this long is dropped, not run.
    static let lifetime: TimeInterval = 15 * 60

    private struct Entry {
        let id = UUID()
        let queuedAt: Date
        let state: () -> AgentSessionState?
        let run: () async -> Void
        let drop: (String) -> Void
    }

    private var entries: [CanvasCardID: Entry] = [:]
    private let now: @MainActor () -> Date

    init(now: @escaping @MainActor () -> Date = { Date() }) { self.now = now }

    func isPending(_ card: CanvasCardID) -> Bool { entries[card] != nil }

    /// Keeps `run` for the node, replacing an earlier change (which is
    /// dropped with a reason). `state` must read observable state, so a
    /// change re-checks it. Returns true when an earlier change was replaced.
    @discardableResult
    func enqueue(
        _ card: CanvasCardID, state: @escaping () -> AgentSessionState?,
        run: @escaping () async -> Void,
        drop: @escaping (String) -> Void
    ) -> Bool {
        let replaced = entries.removeValue(forKey: card)
        replaced?.drop("A newer change replaced it.")
        let entry = Entry(queuedAt: now(), state: state, run: run, drop: drop)
        entries[card] = entry
        arm(card, id: entry.id)
        return replaced != nil
    }

    func cancel(_ card: CanvasCardID) {
        entries.removeValue(forKey: card)?.drop("Cancelled.")
    }

    /// Reads the state under observation and acts on it. The change handler
    /// runs before the new value is stored, so it re-arms on the main actor
    /// afterwards and reads the value then.
    private func arm(_ card: CanvasCardID, id: UUID) {
        guard let entry = entries[card], entry.id == id else { return }
        let state = withObservationTracking {
            entry.state()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.arm(card, id: id) }
        }
        evaluate(card, entry: entry, state: state)
    }

    private func evaluate(_ card: CanvasCardID, entry: Entry, state: AgentSessionState?) {
        if now().timeIntervalSince(entry.queuedAt) > Self.lifetime {
            entries.removeValue(forKey: card)
            entry.drop("It waited more than 15 minutes.")
            return
        }
        switch state {
        case .finished:
            entries.removeValue(forKey: card)
            Task { @MainActor in await entry.run() }
        case .ended, nil:
            entries.removeValue(forKey: card)
            entry.drop("The agent stopped before its turn ended.")
        case .working, .waitingForPermission, .needsInput:
            break
        }
    }
}
