import Foundation

// `agent_configure`: change the model, effort or mode of a Claude Code or Codex
// agent that runs in an Ensemble terminal, also in the middle of a
// conversation. Everything here is pure: allowlists, the ordered steps of each
// strategy, and the readback matcher. Every typed line is a fixed template
// plus allowlisted tokens; nothing from the caller is typed as free text.
// CLI facts and what is still unverified: docs/references/agent-cli-commands.md.

/// The agent CLIs `agent_configure` and the launch flags know.
public nonisolated enum CanvasAgentConfigureAgent: String, CaseIterable, Sendable {
    case claude
    case codex

    /// `claude` or `codex` (a `CanvasAgentLaunch` agent name).
    public init?(agent: String) {
        self.init(rawValue: agent)
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }

    /// Efforts the running agent accepts. Claude `/effort` also takes `auto`.
    /// Codex: `low`, `medium`, `high` until more are verified.
    public var efforts: [String] {
        switch self {
        case .claude: ["low", "medium", "high", "xhigh", "max", "auto"]
        case .codex: ["low", "medium", "high"]
        }
    }

    /// Modes, as wire tokens (`mode`). Claude: the permission mode for
    /// `--permission-mode`. Codex: the sandbox for `-c sandbox_mode`. The
    /// modes that remove every check (Claude `bypassPermissions`, Codex
    /// `danger-full-access`) are deliberately absent.
    public var modes: [String] {
        switch self {
        case .claude: ["default", "accept_edits", "plan"]
        case .codex: ["read_only", "workspace_write"]
        }
    }

    /// The CLI value for a mode token.
    func cliMode(_ mode: String) -> String? {
        switch (self, mode) {
        case (.claude, "default"): "default"
        case (.claude, "accept_edits"): "acceptEdits"
        case (.claude, "plan"): "plan"
        case (.codex, "read_only"): "read-only"
        case (.codex, "workspace_write"): "workspace-write"
        default: nil
        }
    }

    /// The default strategy: Claude changes model and effort in place; Codex
    /// has no in-place form (its `/model` opens a picker), so it resumes.
    public var defaultStrategy: CanvasAgentConfigureStrategy {
        self == .claude ? .inPlace : .resume
    }

    /// The line that quits the agent and leaves the shell. Unverified for
    /// both CLIs (`/exit`, `/quit`); see the reference note.
    public var exitLine: String {
        switch self {
        case .claude: "/exit"
        case .codex: "/quit"
        }
    }
}

public nonisolated enum CanvasAgentConfigureStrategy: String, CaseIterable, Sendable {
    /// Type `/model` and `/effort` into the running agent (Claude only).
    case inPlace = "in_place"
    /// Quit the agent, then resume the same conversation with flags.
    case resume
}

/// What the caller asked to change. Every value is an allowlisted token.
public nonisolated struct CanvasAgentConfigureRequest: Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var mode: String?

    public init(model: String? = nil, effort: String? = nil, mode: String? = nil) {
        self.model = model
        self.effort = effort
        self.mode = mode
    }

    public var isEmpty: Bool { model == nil && effort == nil && mode == nil }
}

/// Matches the agent's answer in the viewport. A line counts only when it is
/// new since the step began and does not hold one of the typed commands, so
/// the echo of `/model sonnet` never confirms itself. Every token must appear
/// as a whole word, ignoring case.
public nonisolated struct CanvasAgentReadbackMatcher: Equatable, Sendable {
    public var tokens: [String]
    /// Lines that hold one of these (ignoring case) are the typed commands.
    public var ignoredLineMarkers: [String]

    public init(tokens: [String], ignoredLineMarkers: [String]) {
        self.tokens = tokens
        self.ignoredLineMarkers = ignoredLineMarkers
    }

    /// The lines of `after` that are not in `before` (as a multiset) and are
    /// not a typed command.
    public func freshLines(before: [String], after: [String]) -> [String] {
        var seen: [String: Int] = [:]
        for line in before { seen[line, default: 0] += 1 }
        var fresh: [String] = []
        for line in after {
            if let count = seen[line], count > 0 {
                seen[line] = count - 1
                continue
            }
            let lowered = line.lowercased()
            if ignoredLineMarkers.contains(where: { lowered.contains($0.lowercased()) }) {
                continue
            }
            fresh.append(line)
        }
        return fresh
    }

    /// True when every token appears as a word in the fresh lines.
    public func matches(before: [String], after: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let text = freshLines(before: before, after: after).joined(separator: "\n").lowercased()
        return tokens.allSatisfy { Self.containsWord($0.lowercased(), in: text) }
    }

    /// At most this many characters of readback go to the caller.
    public static let maximumReadbackCharacters = 200

    /// The fresh lines, scrubbed of secrets (`VoiceOutputScrubber`), joined
    /// with " / ", and cut to the newest `maximumReadbackCharacters`.
    public func readback(before: [String], after: [String]) -> String {
        let scrubbed = VoiceOutputScrubber.scrub(
            lines: freshLines(before: before, after: after), maxLines: 12, maxLineBytes: 200,
            maxBytes: 2_048)
        let joined = scrubbed.split(separator: "\n").joined(separator: " / ")
        let limit = Self.maximumReadbackCharacters
        guard joined.count > limit else { return joined }
        return "…" + String(joined.suffix(limit - 1))
    }

    /// `token` with no letter, digit, `-`, `.` or `_` right before or after it.
    static func containsWord(_ token: String, in text: String) -> Bool {
        guard !token.isEmpty else { return false }
        func isWordCharacter(_ character: Character) -> Bool {
            character.isLetter || character.isNumber || character == "-" || character == "_"
                || character == "."
        }
        var searchStart = text.startIndex
        while let range = text.range(of: token, range: searchStart..<text.endIndex) {
            let before =
                range.lowerBound > text.startIndex
                ? text[text.index(before: range.lowerBound)] : nil
            let after = range.upperBound < text.endIndex ? text[range.upperBound] : nil
            // A trailing `.` ends a sentence; it is not part of the word.
            let afterIsWord = after.map { $0 != "." && isWordCharacter($0) } ?? false
            if !(before.map(isWordCharacter) ?? false), !afterIsWord { return true }
            searchStart = text.index(after: range.lowerBound)
        }
        return false
    }
}

/// One ordered step of a plan.
public nonisolated enum CanvasAgentConfigureStep: Equatable, Sendable {
    /// A slash command typed into the running agent.
    case agentLine(String)
    /// The line that quits the agent; the shell must come back before the
    /// next step.
    case exitAgent(String)
    /// An argument vector typed into the shell, quoted by `CanvasAgentShell`.
    case shellCommand([String])
    /// Wait for the agent CLI to be in front again before the next line.
    case waitForAgent
    /// Read the viewport and match the agent's answer.
    case readback(CanvasAgentReadbackMatcher)
}

/// Why a plan cannot be made. `code` is the stable word for the caller.
public nonisolated enum CanvasAgentConfigureRefusal: Error, Equatable, Sendable {
    case nothingToChange
    case invalidModel
    case invalidEffort(agent: CanvasAgentConfigureAgent)
    case invalidMode(agent: CanvasAgentConfigureAgent)
    case unsupportedInPlace(agent: CanvasAgentConfigureAgent)
    case noSession(agent: CanvasAgentConfigureAgent)

    public var code: String {
        switch self {
        case .nothingToChange, .invalidModel, .invalidEffort, .invalidMode: "invalid_arguments"
        case .unsupportedInPlace: "unsupported_in_place"
        case .noSession: "no_session"
        }
    }

    public var message: String {
        switch self {
        case .nothingToChange: return "Give model, effort or mode."
        case .invalidModel:
            return
                "model must be lowercase letters, digits, '.', '-' or '_', start with a letter or digit, and hold at most 64 characters."
        case .invalidEffort(let agent):
            return
                "\(agent.displayName) accepts effort \(agent.efforts.joined(separator: ", "))."
        case .invalidMode(let agent):
            return "\(agent.displayName) accepts mode \(agent.modes.joined(separator: ", "))."
        case .unsupportedInPlace(let agent):
            if agent == .codex {
                return
                    "Codex cannot change its model in place. Use strategy resume: Codex quits and resumes the same conversation."
            }
            return
                "Claude Code cannot change its mode in place. Use strategy resume: Claude Code quits and resumes the same conversation with the new mode."
        case .noSession(let agent):
            return
                "Rafu does not know the \(agent.displayName) conversation id for this terminal, so it cannot resume it. Connect agent hooks in Settings > Agents, or change the model inside the agent."
        }
    }
}

/// The ordered steps for one `agent_configure` call.
public nonisolated struct CanvasAgentConfigurePlan: Equatable, Sendable {
    public let agent: CanvasAgentConfigureAgent
    public let strategy: CanvasAgentConfigureStrategy
    public let steps: [CanvasAgentConfigureStep]

    /// Quits and restarts the agent process; the Confirm is destructive.
    public var restartsAgent: Bool { strategy == .resume }

    /// `model`: `^[a-z0-9][a-z0-9._-]{0,63}$`.
    public static func isValidModel(_ value: String) -> Bool {
        let scalars = Array(value.unicodeScalars)
        guard (1...64).contains(scalars.count) else { return false }
        func isLowerAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard isLowerAlphanumeric(scalars[0]) else { return false }
        return scalars.dropFirst().allSatisfy {
            isLowerAlphanumeric($0) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }

    /// Every effort any agent accepts (for parsing before the agent is known).
    public static var allEfforts: Set<String> {
        Set(CanvasAgentConfigureAgent.allCases.flatMap(\.efforts))
    }

    /// Every mode any agent accepts.
    public static var allModes: Set<String> {
        Set(CanvasAgentConfigureAgent.allCases.flatMap(\.modes))
    }

    /// Checks the request against the agent's allowlists.
    public static func validate(
        _ request: CanvasAgentConfigureRequest, agent: CanvasAgentConfigureAgent
    ) throws(CanvasAgentConfigureRefusal) {
        guard !request.isEmpty else { throw .nothingToChange }
        if let model = request.model, !isValidModel(model) { throw .invalidModel }
        if let effort = request.effort, !agent.efforts.contains(effort) {
            throw .invalidEffort(agent: agent)
        }
        if let mode = request.mode, !agent.modes.contains(mode) {
            throw .invalidMode(agent: agent)
        }
    }

    /// The strategy a call runs: the requested one, else the agent's default.
    /// A Claude mode change has no in-place form.
    public static func strategy(
        for request: CanvasAgentConfigureRequest, agent: CanvasAgentConfigureAgent,
        requested: CanvasAgentConfigureStrategy?
    ) throws(CanvasAgentConfigureRefusal) -> CanvasAgentConfigureStrategy {
        let strategy = requested ?? agent.defaultStrategy
        if strategy == .inPlace {
            if agent == .codex || request.mode != nil { throw .unsupportedInPlace(agent: agent) }
        }
        return strategy
    }

    /// The plan. `sessionID` is the conversation to resume; a resume without
    /// a safe one is refused.
    public static func make(
        agent: CanvasAgentConfigureAgent, request: CanvasAgentConfigureRequest,
        strategy requested: CanvasAgentConfigureStrategy?, sessionID: String?
    ) throws(CanvasAgentConfigureRefusal) -> CanvasAgentConfigurePlan {
        try validate(request, agent: agent)
        let strategy = try strategy(for: request, agent: agent, requested: requested)
        switch strategy {
        case .inPlace:
            var steps: [CanvasAgentConfigureStep] = []
            var tokens: [String] = []
            if let model = request.model {
                steps.append(.agentLine("/model \(model)"))
                tokens.append(model)
            }
            if let effort = request.effort {
                steps.append(.agentLine("/effort \(effort)"))
                tokens.append(effort)
            }
            steps.append(
                .readback(
                    CanvasAgentReadbackMatcher(
                        tokens: tokens, ignoredLineMarkers: ["/model", "/effort"])))
            return CanvasAgentConfigurePlan(agent: agent, strategy: strategy, steps: steps)
        case .resume:
            guard let sessionID,
                let argv = AgentHistoryResumeCommand.arguments(
                    for: AgentHistorySessionKey(
                        provider: agent.historyProvider, sessionID: sessionID),
                    model: request.model, effort: request.effort, mode: request.mode)
            else { throw .noSession(agent: agent) }
            var steps: [CanvasAgentConfigureStep] = [
                .exitAgent(agent.exitLine), .shellCommand(argv),
            ]
            if agent == .codex {
                // Codex prints its model and effort for `/status` (format
                // unverified). Claude's banner is not a reliable readback.
                let tokens = [request.model, request.effort].compactMap { $0 }
                if !tokens.isEmpty {
                    steps += [
                        .waitForAgent, .agentLine("/status"),
                        .readback(
                            CanvasAgentReadbackMatcher(
                                tokens: tokens,
                                ignoredLineMarkers: ["/status", "codex resume", "model="])),
                    ]
                }
            }
            return CanvasAgentConfigurePlan(agent: agent, strategy: strategy, steps: steps)
        }
    }
}

/// Whether the agent can take a change now. Typing `/model` into a running
/// turn, or into a permission or question dialog, would reach the turn or
/// answer the dialog, so only an idle agent takes it.
public nonisolated enum CanvasAgentConfigureReadiness: Equatable, Sendable {
    /// The hook session finished its turn, or (without hooks) the terminal
    /// has been quiet for `quietInterval`.
    case idle
    /// The hook session is mid-turn.
    case busy
    /// The hook session waits for the user: approval or an answer.
    case waitingForUser
    /// No hook session, and the terminal printed within `quietInterval`.
    case busyWithoutHooks
    /// The hook session ended: no agent runs.
    case notRunning

    /// Without hooks, output in this window counts as mid-turn.
    public static let quietInterval: TimeInterval = 3

    /// `hookState` is nil without a matched, current hook session (a stale
    /// `working` session counts as none). `secondsSinceOutput` is nil when
    /// the terminal printed nothing since its process started.
    public static func check(hookState: AgentSessionState?, secondsSinceOutput: TimeInterval?)
        -> Self
    {
        switch hookState {
        case .finished: return .idle
        case .working: return .busy
        case .waitingForPermission, .needsInput: return .waitingForUser
        case .ended: return .notRunning
        case nil:
            if let seconds = secondsSinceOutput, seconds < quietInterval {
                return .busyWithoutHooks
            }
            return .idle
        }
    }

    /// A queued change needs hooks: it runs on the next `Stop`.
    public var canQueue: Bool { self == .busy || self == .waitingForUser }

    public var code: String {
        switch self {
        case .idle: "ok"
        case .busy, .waitingForUser, .busyWithoutHooks: "agent_busy"
        case .notRunning: "agent_not_running"
        }
    }

    public var message: String {
        switch self {
        case .idle: return "The agent is idle."
        case .busy:
            return
                "The agent is mid-turn, so Rafu did not type into it. Ask the user whether to queue the change; with queue true it runs when the turn ends."
        case .waitingForUser:
            return
                "The agent is waiting for the user to answer a question or an approval in its terminal, so Rafu did not type into it. Ask the user to answer it first, or pass queue true to run the change when the turn ends."
        case .busyWithoutHooks:
            return
                "The terminal printed output in the last 3 seconds, so the agent may be mid-turn and Rafu did not type into it. Try again when it is quiet. Connect agent hooks (Settings > Agents) for a reliable check and for queue."
        case .notRunning:
            return "No agent runs in that terminal now."
        }
    }
}

extension CanvasAgentConfigureAgent {
    var historyProvider: AgentHistoryProvider {
        switch self {
        case .claude: .claudeCode
        case .codex: .codex
        }
    }

    init(historyProvider: AgentHistoryProvider) {
        switch historyProvider {
        case .claudeCode: self = .claude
        case .codex: self = .codex
        }
    }

    /// Launch and resume flags for model and effort. Claude: `--model`,
    /// `--effort` (no `auto` at launch: the flag is left out). Codex: `-m`
    /// at launch, `-c model="…"` on `resume` (where `-m` is refused), and
    /// `-c model_reasoning_effort="…"` (key name unverified).
    func flags(model: String?, effort: String?, resume: Bool) -> [String] {
        var flags: [String] = []
        switch self {
        case .claude:
            if let model { flags += ["--model", model] }
            if let effort, effort != "auto" { flags += ["--effort", effort] }
        case .codex:
            if let model { flags += resume ? ["-c", "model=\"\(model)\""] : ["-m", model] }
            if let effort { flags += ["-c", "model_reasoning_effort=\"\(effort)\""] }
        }
        return flags
    }

    /// The mode flag for a resume line.
    func modeFlags(_ mode: String?) -> [String] {
        guard let mode, let value = cliMode(mode) else { return [] }
        switch self {
        case .claude: return ["--permission-mode", value]
        case .codex: return ["-c", "sandbox_mode=\"\(value)\""]
        }
    }
}
