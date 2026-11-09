import Foundation
import RafuCore

/// Why `agent_configure` did not run. `code` is the stable word a caller
/// reads (`agent_busy`, `unsupported_in_place`, ...).
struct CanvasAgentConfigureFailure: Error, Equatable {
    let code: String
    let message: String

    /// The MCP error text: the code first, so an agent can match it.
    var agentText: String { "\(code): \(message)" }
}

/// A checked `agent_configure` call: the agent, its plan, and whether it must
/// wait for the turn to end. `call` carries the resolved strategy, agent and
/// node title, so the question the user sees names the rung.
struct CanvasAgentConfigurePrepared {
    let call: CanvasAgentToolCall
    let card: CanvasCard
    let request: CanvasAgentConfigureRequest
    let plan: CanvasAgentConfigurePlan
    let readiness: CanvasAgentConfigureReadiness
    let terminal: CanvasAgentConfigureTerminal
}

extension CanvasAgentActions {
    static let configureCreatorMessage =
        "Change only agents in terminals you created. Ask the user to change the model in that agent."
    static let configureUnknownAgentMessage =
        "That terminal runs no claude or codex agent that Rafu knows of."

    /// Checks one `agent_configure` call without changing anything: the node,
    /// the creator rule for MCP callers (voice acts for the user, ADR 0035),
    /// the agent, whether it can take the change now, and the plan.
    static func prepareConfigure(
        _ call: CanvasAgentToolCall, caller: CanvasAgentCaller,
        terminal given: CanvasAgentConfigureTerminal? = nil
    ) -> Result<CanvasAgentConfigurePrepared, CanvasAgentConfigureFailure> {
        func fail(_ code: String, _ message: String) -> Result<
            CanvasAgentConfigurePrepared, CanvasAgentConfigureFailure
        > {
            .failure(CanvasAgentConfigureFailure(code: code, message: message))
        }
        guard let card = try? findCard(call.nodeID, in: caller.board),
            case .terminal(let groupID) = card.content
        else { return fail("invalid_arguments", "node_id must name a terminal node.") }
        let creator = CanvasAgentCenter.shared.creator(of: card.id)
        let isVoice = caller.provider == CanvasAgentCaller.voiceProvider
        guard isVoice || creator?.caller == caller.controllerID else {
            return fail("not_allowed", configureCreatorMessage)
        }
        let terminal =
            given
            ?? CanvasAgentConfigureRunner.terminal(card: card, groupID: groupID, caller: caller)
        guard terminal.isLive() else {
            return fail("agent_not_running", CanvasAgentConfigureReadiness.notRunning.message)
        }
        guard let agent = configureAgent(card: card, caller: caller, terminal: terminal) else {
            return fail("unknown_agent", configureUnknownAgentMessage)
        }
        let hookState = terminal.hookState()
        let readiness = CanvasAgentConfigureReadiness.check(
            hookState: hookState, secondsSinceOutput: terminal.secondsSinceOutput())
        // Without hooks, the agent must be the process in front; a shell
        // prompt would take `/model` as a command.
        if readiness == .notRunning || (hookState == nil && terminal.agentInFront() != agent) {
            return fail("agent_not_running", CanvasAgentConfigureReadiness.notRunning.message)
        }
        if readiness != .idle, !(call.queue == true && readiness.canQueue) {
            return fail(readiness.code, readiness.message)
        }
        let request = CanvasAgentConfigureRequest(
            model: call.model, effort: call.effort, mode: call.mode)
        let plan: CanvasAgentConfigurePlan
        do {
            plan = try CanvasAgentConfigurePlan.make(
                agent: agent, request: request,
                strategy: call.strategy.flatMap(CanvasAgentConfigureStrategy.init(rawValue:)),
                sessionID: terminal.sessionID(agent))
        } catch {
            return fail(error.code, error.message)
        }
        var prepared = call
        prepared.strategy = plan.strategy.rawValue
        prepared.agent = agent.rawValue
        prepared.title = CanvasAgentText.validTitle(card.title) ? card.title : nil
        return .success(
            CanvasAgentConfigurePrepared(
                call: prepared, card: card, request: request, plan: plan, readiness: readiness,
                terminal: terminal))
    }

    /// The agent CLI in the node: the bridge client, the process in front,
    /// the agent Rafu started there, or the agent a command launched.
    private static func configureAgent(
        card: CanvasCard, caller: CanvasAgentCaller, terminal: CanvasAgentConfigureTerminal
    ) -> CanvasAgentConfigureAgent? {
        var names: [String?] = []
        if case .terminal(let groupID) = card.content,
            let controllerID = caller.session.terminal.terminalGroup(groupID)?.panes.first?
                .sessionID
        {
            names.append(CanvasLiveBridge.shared.connectedProvider(controllerID: controllerID))
        }
        names.append(terminal.agentInFront()?.rawValue)
        names.append(CanvasAgentCenter.shared.creator(of: card.id)?.agent)
        names.append(CanvasAgentCenter.shared.launchedAgent(of: card.id))
        return names.lazy.compactMap { $0.flatMap(CanvasAgentConfigureAgent.init(agent:)) }.first
    }

    /// Runs an allowed `agent_configure`: now when the agent is idle, else
    /// queued for the end of its turn (the call asked for `queue`).
    static func agentConfigure(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) async
        -> CanvasBridgeResponse
    {
        let prepared: CanvasAgentConfigurePrepared
        switch prepareConfigure(call, caller: caller) {
        case .failure(let failure): return .init(error: failure.agentText)
        case .success(let value): prepared = value
        }
        let title = CanvasAgentText.singleLine(prepared.card.title, limit: 40)
        let name = "\(prepared.plan.agent.displayName) in “\(title)”"
        if prepared.readiness != .idle {
            enqueueConfigure(prepared, caller: caller)
            var result = CanvasAgentToolResult(
                message:
                    "\(name) is mid-turn. Rafu runs the change when its turn ends (within 15 minutes) and does not report back; check ensemble_describe or the terminal later."
            )
            result.nodeID = prepared.card.id.rawValue.uuidString
            result.strategy = "queued"
            result.confirmed = false
            return .init(toolResult: result)
        }
        let outcome = await CanvasAgentConfigureRunner.run(
            prepared.plan, request: prepared.request, terminal: prepared.terminal,
            title: prepared.card.title)
        guard outcome.completed else { return .init(error: "configure_failed: \(outcome.message)") }
        var result = CanvasAgentToolResult(message: outcome.message)
        result.nodeID = prepared.card.id.rawValue.uuidString
        result.strategy = prepared.plan.strategy.rawValue
        result.confirmed = outcome.confirmed
        result.readback = outcome.readback
        return .init(toolResult: result)
    }

    /// Hands the change to the queue. When the turn ends, the board must
    /// still be open with Agent control not Off; the change is checked again
    /// and runs without a second question (the user already confirmed it).
    private static func enqueueConfigure(
        _ prepared: CanvasAgentConfigurePrepared, caller: CanvasAgentCaller
    ) {
        let board = caller.board
        let agentName = caller.agentName
        let action = CanvasAgentTool.agentConfigure.actionTitle
        let title = CanvasAgentText.singleLine(prepared.card.title, limit: 40)
        let record: @MainActor (String) -> Void = { outcome in
            CanvasAgentCenter.shared.record(
                board.id, agent: agentName, action: action, outcome: outcome)
        }
        var call = prepared.call
        call.queue = nil
        let terminal = prepared.terminal
        CanvasAgentConfigureQueue.shared.enqueue(
            prepared.card.id, state: terminal.hookState,
            run: { [weak board] in
                guard let board, caller.session.canvas.boards[board.id] === board,
                    board.agentControlMode != .off
                else {
                    record("Queued change for \"\(title)\" dropped: the Ensemble is closed or Off")
                    return
                }
                guard
                    case .success(let ready) = prepareConfigure(
                        call, caller: caller, terminal: terminal),
                    ready.readiness == .idle
                else {
                    record("Queued change for \"\(title)\" dropped: the agent was not ready")
                    return
                }
                let outcome = await CanvasAgentConfigureRunner.run(
                    ready.plan, request: ready.request, terminal: terminal, title: ready.card.title)
                record(
                    "Queued change for \"\(title)\": \(outcome.confirmed ? "confirmed" : "not confirmed")"
                )
            },
            drop: { reason in record("Queued change for \"\(title)\" dropped: \(reason)") })
    }
}
