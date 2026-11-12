import Foundation

// The agent orchestration contract. An agent CLI calls these tools through the
// Rafu MCP server; the app performs each call on the caller's own Ensemble.
// Everything in this file is pure: validation, policy, quoting, text edits and
// result bounds. The app re-validates every call it receives.

/// Per-Ensemble agent control. Saved with the board. The default is `ask`.
public nonisolated enum CanvasAgentControlMode: String, Codable, CaseIterable, Sendable {
    case off
    case ask
    case allow

    public var title: String {
        switch self {
        case .off: "Off"
        case .ask: "Ask"
        case .allow: "Allow"
        }
    }
}

/// How much a call can change. Read calls never ask.
public nonisolated enum CanvasAgentRisk: String, Codable, Sendable {
    /// Reads the Ensemble. Never asks.
    case read
    /// Changes the board (undoable). Asks in Ask mode unless the user chose
    /// "Always" for that tool on this Ensemble.
    case edit
    /// Removes items, starts processes, types input or opens apps. Asks in Ask
    /// mode every time. Only the Allow mode skips the question.
    case sensitive
}

public nonisolated enum CanvasAgentDecision: Equatable, Sendable {
    case allow
    case ask
    case deny(String)
}

public nonisolated enum CanvasAgentPolicy {
    public static let offMessage =
        "Agent control is Off for this Ensemble. Ask the user to set Agent control to Ask or Allow."

    /// `alwaysAllowed` is the runtime "Always for this Ensemble" grant for the
    /// tool. It never covers a sensitive call.
    public static func decide(
        mode: CanvasAgentControlMode, risk: CanvasAgentRisk, alwaysAllowed: Bool = false
    ) -> CanvasAgentDecision {
        if risk == .read { return .allow }
        switch mode {
        case .off: return .deny(offMessage)
        case .allow: return .allow
        case .ask:
            if risk == .edit, alwaysAllowed { return .allow }
            return .ask
        }
    }
}

/// A sliding-window limit for one agent session.
public nonisolated struct CanvasAgentRateLimiter: Equatable, Sendable {
    public let limit: Int
    public let window: TimeInterval
    private var events: [Date] = []

    public init(limit: Int = 30, window: TimeInterval = 60) {
        self.limit = max(1, limit)
        self.window = max(1, window)
    }

    public mutating func admit(at date: Date) -> Bool {
        events.removeAll { date.timeIntervalSince($0) >= window || $0 > date }
        guard events.count < limit else { return false }
        events.append(date)
        return true
    }
}

public nonisolated enum CanvasAgentToolError: Error, Equatable, Sendable {
    case unknownTool
    case unexpectedArgument(String)
    case missingArgument(String)
    case invalidArgument(String)
    /// An invalid value with the reason and the accepted form. The reason carries
    /// byte counts and limits only, never the offending text.
    case invalidArgumentReason(key: String, reason: String)
    case headingNotFound
    case noteTooLarge
    case textTooLarge(kilobytes: Int)

    public var message: String {
        switch self {
        case .unknownTool: "Unknown Ensemble tool."
        case .unexpectedArgument(let key): "Unexpected argument \"\(key)\"."
        case .missingArgument(let key): "Missing argument \"\(key)\"."
        case .invalidArgument(let key): "Invalid value for \"\(key)\"."
        case .invalidArgumentReason(let key, let reason): "Invalid value for \"\(key)\": \(reason)"
        case .headingNotFound: "No Markdown heading in the note matches \"heading\"."
        case .noteTooLarge: "A note can contain at most 64 KiB of UTF-8 text."
        case .textTooLarge(let kilobytes):
            "\"text\" is too long for this node kind: at most \(kilobytes) KiB of UTF-8."
        }
    }
}

public nonisolated enum CanvasAgentTool: String, CaseIterable, Codable, Sendable {
    case ensembleDescribe = "ensemble_describe"
    case noteRead = "note_read"
    case noteWrite = "note_write"
    case noteCreate = "note_create"
    case nodeCreate = "node_create"
    case nodeUpdate = "node_update"
    case nodeRemove = "node_remove"
    case terminalCreate = "terminal_create"
    case terminalStart = "terminal_start"
    case terminalSend = "terminal_send"
    case edgeCreate = "edge_create"
    case edgeRemove = "edge_remove"
    case linkSetState = "link_set_state"
    case mermaidSet = "mermaid_set"
    case actionStatus = "action_status"
    case iconSearch = "icon_search"
    case frameCreate = "frame_create"
    case export = "export"
    case diagramBuild = "diagram_build"
    case viewRender = "view_render"
    case viewUpdate = "view_update"
    case agentConfigure = "agent_configure"

    /// The words shown in the approval and the activity log.
    public var actionTitle: String {
        switch self {
        case .ensembleDescribe: "Read the Ensemble"
        case .noteRead: "Read a note"
        case .noteWrite: "Change a note"
        case .noteCreate: "Add a note"
        case .nodeCreate: "Add a node"
        case .nodeUpdate: "Change a node"
        case .nodeRemove: "Remove a node"
        case .terminalCreate: "Add a terminal"
        case .terminalStart: "Start a terminal"
        case .terminalSend: "Type into a terminal"
        case .edgeCreate: "Add a link"
        case .edgeRemove: "Remove a link"
        case .linkSetState: "Change a link state"
        case .mermaidSet: "Change a diagram"
        case .actionStatus: "Read an action status"
        case .iconSearch: "Search icons"
        case .frameCreate: "Add a frame"
        case .export: "Export to a file"
        case .diagramBuild: "Build a diagram"
        case .viewRender: "Show a view"
        case .viewUpdate: "Change a view"
        case .agentConfigure: "Change an agent's model or effort"
        }
    }
}

/// One validated call. The wire form is internal to Rafu (MCP server to app).
public nonisolated struct CanvasAgentToolCall: Codable, Hashable, Sendable {
    public var tool: CanvasAgentTool
    public var nodeID: String?
    public var from: String?
    public var to: String?
    public var edgeID: String?
    public var kind: String?
    public var title: String?
    /// Note text, Markdown, Mermaid source, text-node text, or a terminal line.
    public var text: String?
    public var mode: String?
    public var heading: String?
    public var label: String?
    /// A node ID to place a new node beside.
    public var near: String?
    public var x: Double?
    public var y: Double?
    public var width: Double?
    public var height: Double?
    public var cwd: String?
    public var agent: String?
    /// An argument vector. Rafu quotes each element; it never runs a shell string.
    public var command: [String]?
    public var prompt: String?
    /// `terminal_create`: also link the new terminal to the caller by a message link.
    public var link: Bool?
    public var state: String?
    public var path: String?
    public var url: String?
    public var shape: String?
    public var requestID: String?
    public var offset: Int?
    public var length: Int?
    public var packID: String?
    public var iconID: String?
    public var query: String?
    public var limit: Int?
    public var memberIDs: [String]?
    /// Export target: board, selection or frame (with `frameID`).
    public var target: String?
    public var frameID: String?
    /// Export format: png, pdf or gif.
    public var format: String?
    public var scale: Double?
    public var seconds: Double?
    public var fps: Int?
    public var diagram: CanvasAgentDiagramSpec?
    /// `view_render` / `view_update`: the spec as canonical JSON text (the
    /// server re-serialises the `spec` object with sorted keys), at most
    /// `maximumViewBytes` per call.
    public var viewSpec: String?
    /// `view_update`: JSONL SpecStream patches, at most `maximumViewBytes` and
    /// `maximumViewPatchLines` lines.
    public var viewPatches: String?
    /// `view_update`: restore the view's initial state (Reset View).
    public var reset: Bool?
    /// `agent_configure` and `terminal_create`: an allowlisted model token.
    public var model: String?
    /// `agent_configure` and `terminal_create`: an allowlisted effort token.
    public var effort: String?
    /// `agent_configure`: `in_place` or `resume`. The app fills in the
    /// agent's default before it asks the user, so the question names it.
    public var strategy: String?
    /// `agent_configure`: when the agent is mid-turn, keep the change and run
    /// it when the turn ends.
    public var queue: Bool?

    public init(tool: CanvasAgentTool) { self.tool = tool }

    /// One MCP frame is 64 KiB (`CanvasBridgeMCPServer.maximumFrameBytes`), so
    /// one call carries at most 48 KiB of view JSON. A card holds up to 256 KiB,
    /// reachable through `view_update` patches.
    public static let maximumViewBytes = 48 * 1_024
    public static let maximumViewPatchLines = 2_000
    public static let maximumViewElements = 2_000

    public static let nodeKinds = [
        "note", "terminal", "file", "image", "web", "mermaid", "shape", "text",
        "service_icon", "frame",
    ]
    public static let exportTargets = ["board", "selection", "frame"]
    public static let exportFormats = ["png", "pdf", "gif"]
    public static let maximumFrameMembers = 100
    public static let edgeKinds = ["relationship", "message"]
    public static let linkStates = ["live", "paused"]
    public static let shapes = ["rectangle", "ellipse", "diamond"]
    public static let maximumTextBytes = 16 * 1_024
    public static let maximumPromptBytes = 4 * 1_024
    public static let maximumCommandBytes = 4 * 1_024
    public static let maximumCommandArguments = 32
    /// One argument is typed inside one shell line. This 1,024-byte bound and
    /// the 4,096-byte bound on the whole line are deliberate limits on a line
    /// typed into a terminal, and on a prompt that must stay one positional
    /// argument rather than a variadic-flag hazard (commit d79f9fe). They are
    /// not a measured tty limit.
    public static let maximumCommandArgumentBytes = 1_024
    public static let maximumNoteSliceScalars = 4_000

    /// The risk of the call itself. `terminal_send` into a live message link is
    /// downgraded by the app, which knows the link state.
    public var risk: CanvasAgentRisk {
        switch tool {
        case .ensembleDescribe, .noteRead, .actionStatus, .iconSearch: .read
        case .nodeRemove, .edgeRemove, .terminalStart, .terminalSend, .export, .agentConfigure:
            .sensitive
        case .terminalCreate: startsProcess ? .sensitive : .edit
        default: .edit
        }
    }

    /// True when the call starts a shell, an agent or a command.
    public var startsProcess: Bool {
        switch tool {
        case .terminalStart: true
        case .terminalCreate: agent != nil || command != nil
        default: false
        }
    }

    /// Bounded, single-line parameters for the approval. Never includes the
    /// full note text or message body; those show only as a byte count.
    public var approvalSummary: [String] {
        var lines: [String] = []
        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            lines.append("\(name): \(CanvasAgentText.singleLine(value, limit: 160))")
        }
        add("Node", nodeID)
        add("From", from)
        add("To", to)
        add("Link", edgeID)
        add("Kind", kind)
        add("Title", title)
        add("Mode", mode)
        add("Heading", heading)
        add("Label", label)
        add("Folder", cwd)
        add("Agent", agent)
        add("Model", model)
        add("Effort", effort)
        if let strategy {
            lines.append(
                strategy == CanvasAgentConfigureStrategy.resume.rawValue
                    ? "Restart: the agent quits and resumes the same conversation"
                    : "In place: Rafu types the change into the running agent")
        }
        if queue == true { lines.append("Queue: run when the agent's turn ends") }
        if link == true { lines.append("Link: live message link to this terminal") }
        if let command { add("Command", CanvasAgentShell.commandLine(command)) }
        add("State", state)
        add("Path", path)
        add("URL", url)
        if let packID, let iconID { add("Icon", "\(packID)/\(iconID)") }
        if let memberIDs { lines.append("Members: \(memberIDs.count) nodes") }
        add("Target", target.map { $0 == "frame" ? "frame \(frameID ?? "")" : $0 })
        add("Format", format)
        if let diagram {
            lines.append("Diagram: \(diagram.nodes.count) nodes, \(diagram.edges.count) links")
            add("Frame", diagram.frame)
        }
        if let viewSpec { lines.append("View: \(CanvasAgentViewSummary.line(specJSON: viewSpec))") }
        if let viewPatches {
            let count = viewPatches.split(whereSeparator: \.isNewline).count
            lines.append("Patches: \(count) \(count == 1 ? "line" : "lines")")
        }
        if reset == true { lines.append("Reset the view's state") }
        if let prompt { lines.append("Task: \(CanvasAgentText.singleLine(prompt, limit: 240))") }
        if let text {
            if tool == .terminalSend {
                lines.append("Input: \(CanvasAgentText.singleLine(text, limit: 240))")
            } else {
                lines.append("Text: \(text.utf8.count) bytes")
            }
        }
        return lines
    }

    // MARK: Parsing

    private static func allowedKeys(for tool: CanvasAgentTool) -> Set<String> {
        let placement: Set<String> = ["near", "x", "y"]
        switch tool {
        case .ensembleDescribe: return []
        case .noteRead: return ["node_id", "offset", "length"]
        case .noteWrite: return ["node_id", "text", "mode", "heading"]
        case .noteCreate: return placement.union(["title", "markdown"])
        case .nodeCreate:
            return placement.union([
                "kind", "title", "text", "path", "url", "shape",
                "width", "height", "pack_id", "icon_id", "label", "member_ids",
            ])
        case .nodeUpdate: return ["node_id", "title", "x", "y", "width", "height"]
        case .nodeRemove, .terminalStart: return ["node_id"]
        case .terminalCreate:
            return placement.union([
                "title", "cwd", "agent", "command", "prompt", "link", "model", "effort",
            ])
        case .terminalSend: return ["node_id", "text", "command"]
        case .edgeCreate: return ["from", "to", "kind", "label"]
        case .edgeRemove: return ["edge_id"]
        case .linkSetState: return ["edge_id", "state"]
        case .mermaidSet: return ["node_id", "source"]
        case .actionStatus: return ["request_id"]
        case .iconSearch: return ["query", "limit"]
        case .frameCreate: return ["title", "member_ids"]
        case .export: return ["target", "frame_id", "format", "scale", "seconds", "fps"]
        case .diagramBuild: return placement.union(["spec"])
        case .viewRender: return placement.union(["title", "spec"])
        case .viewUpdate: return ["node_id", "spec", "patches", "reset"]
        case .agentConfigure: return ["node_id", "model", "effort", "mode", "strategy", "queue"]
        }
    }

    /// Validates MCP `arguments`. Unknown keys are rejected.
    public static func parse(tool name: String, arguments: [String: Any])
        throws(CanvasAgentToolError) -> CanvasAgentToolCall
    {
        guard let tool = CanvasAgentTool(rawValue: name) else { throw .unknownTool }
        let allowed = allowedKeys(for: tool)
        for key in arguments.keys.sorted() where !allowed.contains(key) {
            throw .unexpectedArgument(String(key.prefix(64)))
        }
        func string(_ key: String) throws(CanvasAgentToolError) -> String? {
            guard let value = arguments[key] else { return nil }
            guard let text = value as? String else { throw .invalidArgument(key) }
            return text
        }
        func number(_ key: String) throws(CanvasAgentToolError) -> Double? {
            guard let value = arguments[key] else { return nil }
            guard let number = value as? Double else { throw .invalidArgument(key) }
            return number
        }
        func integer(_ key: String) throws(CanvasAgentToolError) -> Int? {
            guard let value = arguments[key] else { return nil }
            if let number = value as? Int { return number }
            guard let double = value as? Double, double.rounded() == double,
                abs(double) <= 1_000_000_000
            else { throw .invalidArgument(key) }
            return Int(double)
        }
        var call = CanvasAgentToolCall(tool: tool)
        call.nodeID = try string("node_id")
        call.from = try string("from")
        call.to = try string("to")
        call.edgeID = try string("edge_id")
        call.kind = try string("kind")
        call.title = try string("title")
        let plain = try string("text")
        let markdown = try string("markdown")
        let source = try string("source")
        call.text = plain ?? markdown ?? source
        call.mode = try string("mode")
        call.heading = try string("heading")
        call.label = try string("label")
        call.near = try string("near")
        call.x = try number("x")
        call.y = try number("y")
        call.width = try number("width")
        call.height = try number("height")
        call.cwd = try string("cwd")
        call.agent = try string("agent")?.lowercased()
        if let value = arguments["command"] {
            guard let list = value as? [Any], let strings = list as? [String] else {
                throw .invalidArgument("command")
            }
            call.command = strings
        }
        call.prompt = try string("prompt")
        if let value = arguments["link"] {
            guard let flag = value as? Bool else { throw .invalidArgument("link") }
            call.link = flag
        }
        call.state = try string("state")?.lowercased()
        call.path = try string("path")
        call.url = try string("url")
        call.shape = try string("shape")?.lowercased()
        call.requestID = try string("request_id")
        call.offset = try integer("offset")
        call.length = try integer("length")
        call.packID = try string("pack_id")
        call.iconID = try string("icon_id")
        call.query = try string("query")
        call.limit = try integer("limit")
        if let value = arguments["member_ids"] {
            guard let list = value as? [Any], let strings = list as? [String] else {
                throw .invalidArgument("member_ids")
            }
            call.memberIDs = strings
        }
        call.target = try string("target")?.lowercased()
        call.frameID = try string("frame_id")
        call.format = try string("format")?.lowercased()
        call.scale = try number("scale")
        call.seconds = try number("seconds")
        call.fps = try integer("fps")
        if let value = arguments["spec"] {
            if tool == .viewRender || tool == .viewUpdate {
                call.viewSpec = try CanvasAgentViewSpec.canonicalText(value)
            } else {
                guard let object = value as? [String: Any] else {
                    throw .invalidArgument("spec")
                }
                call.diagram = try CanvasAgentDiagramSpec.parse(object)
            }
        }
        call.viewPatches = try string("patches")
        if let value = arguments["reset"] {
            guard let flag = value as? Bool else { throw .invalidArgument("reset") }
            call.reset = flag
        }
        call.model = try string("model")?.lowercased()
        call.effort = try string("effort")?.lowercased()
        call.strategy = try string("strategy")?.lowercased()
        if let value = arguments["queue"] {
            guard let flag = value as? Bool else { throw .invalidArgument("queue") }
            call.queue = flag
        }
        if call.label == nil, call.tool == .nodeCreate, let text = call.title,
            call.kind == "service_icon"
        {
            call.label = text
        }
        call.kind = call.kind?.lowercased()
        call.mode = call.mode?.lowercased()
        try call.validate()
        return call
    }

    // MARK: Validation

    static func lineTextReason(bytes: Int) -> String {
        "the text is \(CanvasAgentShellRefusal.grouped(bytes)) bytes; at most "
            + "\(CanvasAgentShellRefusal.grouped(maximumPromptBytes)) bytes are accepted per call. "
            + CanvasAgentShellRefusal.longBriefAdvice
    }

    /// Both the MCP server and the app call this. It bounds every field.
    public func validate() throws(CanvasAgentToolError) {
        try validateFieldBounds()
        try validateRequirements()
    }

    private func validateFieldBounds() throws(CanvasAgentToolError) {
        for (key, value) in [
            ("node_id", nodeID), ("from", from), ("to", to), ("edge_id", edgeID),
            ("near", near), ("request_id", requestID),
        ] {
            if let value, UUID(uuidString: value) == nil { throw .invalidArgument(key) }
        }
        if let title, !CanvasAgentText.validTitle(title) { throw .invalidArgument("title") }
        if let label, !CanvasAgentText.validTitle(label) { throw .invalidArgument("label") }
        if let text, text.utf8.count > Self.maximumTextBytes || text.contains("\0") {
            if tool == .terminalSend, !text.contains("\0") {
                throw .invalidArgumentReason(
                    key: "text", reason: Self.lineTextReason(bytes: text.utf8.count))
            }
            throw .invalidArgument(tool == .mermaidSet ? "source" : "text")
        }
        if let heading, heading.utf8.count > 200 || heading.contains("\n") {
            throw .invalidArgument("heading")
        }
        if let prompt {
            if prompt.isEmpty || prompt.contains("\0") { throw .invalidArgument("prompt") }
            if prompt.utf8.count > Self.maximumPromptBytes {
                throw .invalidArgumentReason(
                    key: "prompt",
                    reason: CanvasAgentShellRefusal.argumentTooLong(
                        index: 1, bytes: prompt.utf8.count,
                        limit: Self.maximumCommandArgumentBytes
                    ).reason(isPrompt: true))
            }
        }
        for (key, value) in [("x", x), ("y", y)] {
            if let value, !value.isFinite || abs(value) > 50_000 { throw .invalidArgument(key) }
        }
        if let width, !width.isFinite || !(96...2_000).contains(width) {
            throw .invalidArgument("width")
        }
        if let height, !height.isFinite || !(64...2_000).contains(height) {
            throw .invalidArgument("height")
        }
        if let cwd, CanvasAgentPaths.normalizedRelative(cwd, allowRoot: true) == nil {
            throw .invalidArgument("cwd")
        }
        if let path, CanvasAgentPaths.normalizedRelative(path, allowRoot: false) == nil {
            throw .invalidArgument("path")
        }
        if let agent, CanvasAgentLaunch.executable(for: agent) == nil {
            throw .invalidArgument("agent")
        }
        if let command, let refusal = CanvasAgentShell.refusal(for: command) {
            throw .invalidArgumentReason(key: "command", reason: refusal.reason())
        }
        if let url, url.isEmpty || url.utf8.count > 2_048 || CanvasAgentText.hasControl(url) {
            throw .invalidArgument("url")
        }
        if let shape, !Self.shapes.contains(shape) { throw .invalidArgument("shape") }
        if let offset, !(0...1_000_000).contains(offset) { throw .invalidArgument("offset") }
        if let length, !(1...Self.maximumNoteSliceScalars).contains(length) {
            throw .invalidArgument("length")
        }
        if let state, !Self.linkStates.contains(state) { throw .invalidArgument("state") }
        if let mode {
            let valid =
                tool == .agentConfigure
                ? CanvasAgentConfigurePlan.allModes.contains(mode)
                : CanvasAgentNoteMode(rawValue: mode) != nil
            if !valid { throw .invalidArgument("mode") }
        }
        if let model, !CanvasAgentConfigurePlan.isValidModel(model) {
            throw .invalidArgumentReason(
                key: "model", reason: CanvasAgentConfigureRefusal.invalidModel.message)
        }
        if let effort, !CanvasAgentConfigurePlan.allEfforts.contains(effort) {
            throw .invalidArgument("effort")
        }
        if let strategy, CanvasAgentConfigureStrategy(rawValue: strategy) == nil {
            throw .invalidArgument("strategy")
        }
        try validateDiagramFieldBounds()
    }

    private func validateDiagramFieldBounds() throws(CanvasAgentToolError) {
        if let frameID, UUID(uuidString: frameID) == nil { throw .invalidArgument("frame_id") }
        if let memberIDs {
            guard memberIDs.count <= Self.maximumFrameMembers,
                memberIDs.allSatisfy({ UUID(uuidString: $0) != nil })
            else { throw .invalidArgument("member_ids") }
        }
        if let packID, !CanvasAgentText.validIdentifier(packID) {
            throw .invalidArgument("pack_id")
        }
        if let iconID, !CanvasAgentText.validIdentifier(iconID) {
            throw .invalidArgument("icon_id")
        }
        if let query, query.isEmpty || query.utf8.count > 200 || CanvasAgentText.hasControl(query) {
            throw .invalidArgument("query")
        }
        if let limit, !(1...50).contains(limit) { throw .invalidArgument("limit") }
        if let target, !Self.exportTargets.contains(target) { throw .invalidArgument("target") }
        if let format, !Self.exportFormats.contains(format) { throw .invalidArgument("format") }
        if let scale, !scale.isFinite || !(0.5...4).contains(scale) {
            throw .invalidArgument("scale")
        }
        if let seconds, !seconds.isFinite || !(1...10).contains(seconds) {
            throw .invalidArgument("seconds")
        }
        if let fps, !(1...30).contains(fps) { throw .invalidArgument("fps") }
        if let diagram { try diagram.validate() }
        if let viewSpec, viewSpec.utf8.count > Self.maximumViewBytes {
            throw .invalidArgumentReason(
                key: "spec", reason: CanvasAgentViewSpec.tooLargeReason(bytes: viewSpec.utf8.count))
        }
        if let viewPatches { try CanvasAgentViewSpec.validatePatches(viewPatches) }
    }

    private func validateRequirements() throws(CanvasAgentToolError) {
        func require(_ value: Any?, _ key: String) throws(CanvasAgentToolError) {
            if value == nil { throw .missingArgument(key) }
        }
        switch tool {
        case .ensembleDescribe: break
        case .noteRead, .nodeRemove, .terminalStart: try require(nodeID, "node_id")
        case .noteWrite:
            try require(nodeID, "node_id")
            try require(text, "text")
            try require(mode, "mode")
            if mode == CanvasAgentNoteMode.insertAfterHeading.rawValue {
                try require(heading, "heading")
            }
        case .noteCreate: try require(title, "title")
        case .nodeCreate: try validateNodeCreate()
        case .nodeUpdate:
            try require(nodeID, "node_id")
            guard title != nil || x != nil || y != nil || width != nil || height != nil else {
                throw .missingArgument("title")
            }
        case .terminalCreate:
            if prompt != nil {
                guard let agent, CanvasAgentLaunch.acceptsPrompt(agent) else {
                    throw .invalidArgument("prompt")
                }
            }
            if agent != nil, command != nil { throw .invalidArgument("command") }
            if model != nil || effort != nil {
                guard let agent, let known = CanvasAgentConfigureAgent(agent: agent) else {
                    throw .invalidArgumentReason(
                        key: model != nil ? "model" : "effort",
                        reason: "model and effort need agent claude or codex")
                }
                if let effort, !known.efforts.contains(effort) || effort == "auto" {
                    throw .invalidArgumentReason(
                        key: "effort",
                        reason: "\(known.displayName) starts with effort "
                            + known.efforts.filter { $0 != "auto" }.joined(separator: ", "))
                }
            }
            // The prompt becomes one argument of the typed launch line. Refuse here,
            // before any node exists, with the reason.
            if let agent, prompt != nil,
                let argv = CanvasAgentLaunch.argv(
                    agent: agent, prompt: prompt, model: model, effort: effort),
                let refusal = CanvasAgentShell.refusal(for: argv)
            {
                throw .invalidArgumentReason(key: "prompt", reason: refusal.reason(isPrompt: true))
            }
        case .terminalSend:
            try require(nodeID, "node_id")
            guard (text == nil) != (command == nil) else { throw .missingArgument("text") }
            if let text, text.isEmpty { throw .invalidArgument("text") }
            if let text, text.utf8.count > Self.maximumPromptBytes {
                throw .invalidArgumentReason(
                    key: "text", reason: Self.lineTextReason(bytes: text.utf8.count))
            }
        case .edgeCreate:
            try require(from, "from")
            try require(to, "to")
            try require(kind, "kind")
            guard let kind, Self.edgeKinds.contains(kind) else { throw .invalidArgument("kind") }
            guard from != to else { throw .invalidArgument("to") }
        case .edgeRemove: try require(edgeID, "edge_id")
        case .linkSetState:
            try require(edgeID, "edge_id")
            try require(state, "state")
        case .mermaidSet:
            try require(nodeID, "node_id")
            try require(text, "source")
        case .actionStatus: try require(requestID, "request_id")
        case .iconSearch: try require(query, "query")
        case .frameCreate:
            try require(title, "title")
            guard let memberIDs, !memberIDs.isEmpty else { throw .missingArgument("member_ids") }
        case .export:
            try require(format, "format")
            if target == "frame" { try require(frameID, "frame_id") }
            if frameID != nil, target != nil, target != "frame" {
                throw .invalidArgument("frame_id")
            }
            if scale != nil, format != "png" { throw .invalidArgument("scale") }
            if seconds != nil || fps != nil, format != "gif" { throw .invalidArgument("seconds") }
        case .diagramBuild: try require(diagram, "spec")
        case .viewRender: try require(viewSpec, "spec")
        case .agentConfigure:
            try require(nodeID, "node_id")
            if model == nil, effort == nil, mode == nil { throw .missingArgument("model") }
        case .viewUpdate:
            try require(nodeID, "node_id")
            let given = [viewSpec != nil, viewPatches != nil, reset == true].filter { $0 }.count
            if given == 0 { throw .missingArgument("spec") }
            if given > 1 {
                throw .invalidArgumentReason(
                    key: "spec", reason: "give spec, patches or reset, not two")
            }
        }
    }

    private func validateNodeCreate() throws(CanvasAgentToolError) {
        guard let kind else { throw .missingArgument("kind") }
        guard Self.nodeKinds.contains(kind) else { throw .invalidArgument("kind") }
        switch kind {
        case "file", "image": if path == nil { throw .missingArgument("path") }
        case "web": if url == nil { throw .missingArgument("url") }
        case "service_icon":
            if packID == nil { throw .missingArgument("pack_id") }
            if iconID == nil { throw .missingArgument("icon_id") }
        case "frame":
            if title == nil { throw .missingArgument("title") }
        default: break
        }
    }
}

// MARK: Note editing

public nonisolated enum CanvasAgentNoteMode: String, CaseIterable, Sendable {
    case append
    case prepend
    case replace
    case insertAfterHeading = "insert_after_heading"
}

/// A minimal replacement in UTF-16 units, ready for a native text view.
public nonisolated struct CanvasAgentTextEdit: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let replacement: String
    public let result: String
}

public nonisolated enum CanvasAgentNoteEditor {
    public static let maximumNoteBytes = 64 * 1_024

    public static func edit(
        _ existing: String, mode: CanvasAgentNoteMode, text: String, heading: String? = nil,
        limit: Int = maximumNoteBytes
    ) throws(CanvasAgentToolError) -> CanvasAgentTextEdit {
        let edit: CanvasAgentTextEdit
        let count = existing.utf16.count
        switch mode {
        case .replace:
            edit = .init(location: 0, length: count, replacement: text, result: text)
        case .append:
            let separator = existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n"
            let addition = separator + text
            edit = .init(
                location: count, length: 0, replacement: addition, result: existing + addition)
        case .prepend:
            let separator = existing.isEmpty || text.hasSuffix("\n") ? "" : "\n"
            let addition = text + separator
            edit = .init(
                location: 0, length: 0, replacement: addition, result: addition + existing)
        case .insertAfterHeading:
            guard let heading, let lineEnd = headingLineEnd(in: existing, heading: heading)
            else { throw .headingNotFound }
            let prefix = String(existing[..<lineEnd])
            let needsBreak = !prefix.hasSuffix("\n")
            let addition = (needsBreak ? "\n" : "") + text + (text.hasSuffix("\n") ? "" : "\n")
            let suffix = String(existing[lineEnd...])
            edit = .init(
                location: prefix.utf16.count, length: 0, replacement: addition,
                result: prefix + addition + suffix)
        }
        guard edit.result.utf8.count <= limit else { throw .noteTooLarge }
        return edit
    }

    /// The index just after the first matching ATX heading line (including its
    /// newline). Matching ignores case, `#` marks and surrounding spaces.
    static func headingLineEnd(in text: String, heading: String) -> String.Index? {
        let wanted = normalizedHeading(heading)
        guard !wanted.isEmpty else { return nil }
        var index = text.startIndex
        while index < text.endIndex {
            let end = text[index...].firstIndex(of: "\n") ?? text.endIndex
            let line = text[index..<end]
            let trimmed = line.drop(while: { $0 == " " })
            let marks = trimmed.prefix(while: { $0 == "#" }).count
            if (1...6).contains(marks) {
                let rest = trimmed.dropFirst(marks)
                if rest.isEmpty || rest.first == " " || rest.first == "\t",
                    normalizedHeading(String(rest)) == wanted
                {
                    return end < text.endIndex ? text.index(after: end) : end
                }
            }
            guard end < text.endIndex else { break }
            index = text.index(after: end)
        }
        return nil
    }

    private static func normalizedHeading(_ value: String) -> String {
        var text = value.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        while text.hasSuffix("#") { text.removeLast() }
        return text.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// A slice in Unicode scalars, so a split never breaks a scalar.
    public static func slice(_ text: String, offset: Int, length: Int) -> (
        text: String, total: Int, truncated: Bool
    ) {
        let scalars = text.unicodeScalars
        let total = scalars.count
        let start = min(max(0, offset), total)
        let end = min(total, start + max(0, length))
        let lower = scalars.index(scalars.startIndex, offsetBy: start)
        let upper = scalars.index(lower, offsetBy: end - start)
        return (String(scalars[lower..<upper]), total, end < total)
    }
}

// MARK: Text, paths, shell

public nonisolated enum CanvasAgentText {
    public static func hasControl(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// Matches the board's title rule: non-empty, at most 120 scalars, no controls.
    public static func validTitle(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.unicodeScalars.count <= 120 && !hasControl(value)
    }

    /// An icon-pack or icon identifier: letters, digits, `.`, `-`, `_`, `/`.
    public static func validIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_/")
        return !value.isEmpty && value.utf8.count <= 200 && !value.hasPrefix("/")
            && !value.contains("..") && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Control characters become spaces; the result holds at most `maxBytes` bytes
    /// of UTF-8, cut on a scalar boundary, with no ellipsis. For a line that is
    /// typed into a terminal, where a count in scalars would not bound the bytes.
    public static func singleLine(_ value: String, maxBytes: Int) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        for scalar in value.unicodeScalars {
            let kept: Unicode.Scalar =
                CharacterSet.controlCharacters.contains(scalar) ? " " : scalar
            let size = String(kept).utf8.count
            if bytes + size > maxBytes { break }
            scalars.append(kept)
            bytes += size
        }
        return String(scalars)
    }

    /// Control characters become spaces; the result is cut to `limit` scalars.
    public static func singleLine(_ value: String, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            if scalars.count >= limit {
                scalars.append("…")
                break
            }
            scalars.append(CharacterSet.controlCharacters.contains(scalar) ? " " : scalar)
        }
        return String(scalars)
    }
}

public nonisolated enum CanvasAgentPaths {
    /// A lexical workspace-relative path: no leading `/`, no `..`, no `~`,
    /// no NUL or control characters. `.` parts are dropped. The app resolves
    /// symbolic links against the workspace root before it uses the path.
    public static func normalizedRelative(_ path: String, allowRoot: Bool) -> String? {
        guard path.utf8.count <= 4_096, !path.hasPrefix("/"), !path.hasPrefix("~"),
            !CanvasAgentText.hasControl(path)
        else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." }) else { return nil }
        let kept = parts.filter { $0 != "." }.joined(separator: "/")
        if kept.isEmpty { return allowRoot ? "." : nil }
        return kept
    }
}

public nonisolated enum CanvasAgentShell {
    private static let plain = CharacterSet(
        charactersIn:
            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_@%+=:,./-")

    /// POSIX single-quote quoting of one argument.
    public static func quote(_ argument: String) -> String {
        if !argument.isEmpty, argument.unicodeScalars.allSatisfy({ plain.contains($0) }) {
            return argument
        }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// One shell line from an argument vector, or nil when `refusal(for:)` finds
    /// a reason. Each element is quoted, so no element can add a pipe, redirect,
    /// substitution or second command.
    public static func commandLine(_ argv: [String]) -> String? {
        guard refusal(for: argv) == nil else { return nil }
        return argv.map(quote).joined(separator: " ")
    }

    /// Why `commandLine` would refuse `argv`, or nil when it accepts it. Carries
    /// indices, byte counts and limits only, never the argument text.
    public static func refusal(for argv: [String]) -> CanvasAgentShellRefusal? {
        guard let first = argv.first, !first.isEmpty else { return .empty }
        let maximumArguments = CanvasAgentToolCall.maximumCommandArguments
        guard argv.count <= maximumArguments else {
            return .tooManyArguments(count: argv.count, limit: maximumArguments)
        }
        let argumentLimit = CanvasAgentToolCall.maximumCommandArgumentBytes
        for (index, argument) in argv.enumerated() {
            if CanvasAgentText.hasControl(argument) { return .controlCharacter(index: index) }
            let bytes = argument.utf8.count
            if bytes > argumentLimit {
                return .argumentTooLong(index: index, bytes: bytes, limit: argumentLimit)
            }
        }
        let lineBytes = argv.map(quote).joined(separator: " ").utf8.count
        let lineLimit = CanvasAgentToolCall.maximumCommandBytes
        if lineBytes > lineLimit { return .lineTooLong(bytes: lineBytes, limit: lineLimit) }
        return nil
    }
}

/// Why a typed shell line was refused. `index` counts from zero.
public nonisolated enum CanvasAgentShellRefusal: Equatable, Sendable {
    case empty
    case tooManyArguments(count: Int, limit: Int)
    case controlCharacter(index: Int)
    case argumentTooLong(index: Int, bytes: Int, limit: Int)
    case lineTooLong(bytes: Int, limit: Int)

    static let longBriefAdvice =
        "Put a long brief in a file or a Rafu note, then pass a short one-line text that names the path or the note title."

    /// 1,024-style digit grouping, independent of the user's locale.
    static func grouped(_ number: Int) -> String {
        let digits = String(abs(number))
        var grouped = ""
        for (offset, digit) in digits.reversed().enumerated() {
            if offset > 0, offset % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return (number < 0 ? "-" : "") + String(grouped.reversed())
    }

    /// The reason for an agent to read. `isPrompt` words it for `prompt`, the
    /// second argument of the agent launch line.
    public func reason(isPrompt: Bool = false) -> String {
        let accepted =
            "The line is typed as one line: at most "
            + "\(CanvasAgentToolCall.maximumCommandArguments) arguments, "
            + "\(Self.grouped(CanvasAgentToolCall.maximumCommandArgumentBytes)) bytes each, "
            + "\(Self.grouped(CanvasAgentToolCall.maximumCommandBytes)) bytes in all, "
            + "and no control characters."
        switch self {
        case .empty:
            return "the argument array is empty or its first element is empty."
        case .tooManyArguments(let count, let limit):
            return "\(count) arguments; at most \(limit) are accepted. \(accepted)"
        case .controlCharacter(let index):
            return "argument \(index + 1) contains a control character such as a newline or tab. "
                + accepted
        case .argumentTooLong(let index, let bytes, let limit):
            let subject = isPrompt ? "the prompt" : "argument \(index + 1)"
            let detail =
                isPrompt
                ? "A prompt is typed as one argument of the launch line, so newlines become spaces and it holds at most \(Self.grouped(limit)) bytes."
                : "Each argument holds at most \(Self.grouped(limit)) bytes of UTF-8 and the whole line at most \(Self.grouped(CanvasAgentToolCall.maximumCommandBytes))."
            return "\(subject) is \(Self.grouped(bytes)) bytes. \(detail) \(Self.longBriefAdvice)"
        case .lineTooLong(let bytes, let limit):
            return
                "the quoted line is \(Self.grouped(bytes)) bytes; at most \(Self.grouped(limit)) are accepted. "
                + Self.longBriefAdvice
        }
    }
}

public nonisolated enum CanvasAgentLaunch {
    /// Agent name → executable name on `PATH`. Only `claude` and `codex` attach
    /// to the Ensemble bridge; the others run as ordinary terminal programs.
    public static let executables: [String: String] = [
        "claude": "claude", "codex": "codex", "opencode": "opencode", "gemini": "gemini",
        "cursor": "cursor-agent", "cursor-agent": "cursor-agent", "kimi": "kimi", "cline": "cline",
    ]

    public static func executable(for agent: String) -> String? { executables[agent] }

    /// The agent CLI a command starts, when its program is one Rafu knows. Only a
    /// hint: nothing proves the program runs or registered with the bridge.
    public static func agent(forCommand argv: [String]) -> String? {
        guard let first = argv.first else { return nil }
        let program = first.split(separator: "/").last.map(String.init) ?? first
        return executables[program] == nil ? nil : program
    }

    /// Claude Code and Codex accept an initial task as one positional argument
    /// and stay interactive.
    public static func acceptsPrompt(_ agent: String) -> Bool {
        agent == "claude" || agent == "codex"
    }

    /// The argument vector that starts the agent with an optional first task.
    /// Control characters in the task become spaces so it stays one line.
    public static func argv(agent: String, prompt: String?) -> [String]? {
        argv(agent: agent, prompt: prompt, model: nil, effort: nil)
    }

    /// The launch vector with model and effort flags before the task:
    /// Claude `--model X --effort Y`, Codex `-m X -c model_reasoning_effort="Y"`.
    /// nil when model or effort is given for another agent or fails its
    /// allowlist; `auto` is not a launch effort.
    public static func argv(agent: String, prompt: String?, model: String?, effort: String?)
        -> [String]?
    {
        guard let executable = executable(for: agent) else { return nil }
        var head = [executable]
        if model != nil || effort != nil {
            guard let known = CanvasAgentConfigureAgent(agent: agent) else { return nil }
            if let model, !CanvasAgentConfigurePlan.isValidModel(model) { return nil }
            if let effort, !known.efforts.contains(effort) || effort == "auto" { return nil }
            head += known.flags(model: model, effort: effort, resume: false)
        }
        guard let prompt else { return head }
        guard acceptsPrompt(agent) else { return nil }
        let line = CanvasAgentText.singleLine(
            prompt, maxBytes: CanvasAgentToolCall.maximumPromptBytes
        )
        .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? head : head + [line]
    }
}

// MARK: Results

public nonisolated struct CanvasAgentNodeSummary: Codable, Hashable, Sendable {
    public var id: String
    public var kind: String
    public var title: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var state: String?
    public var agent: String?
    public var path: String?

    public init(
        id: String, kind: String, title: String, x: Double, y: Double, width: Double,
        height: Double, state: String? = nil, agent: String? = nil, path: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.state = state
        self.agent = agent
        self.path = path
    }
}

public nonisolated struct CanvasAgentEdgeSummary: Codable, Hashable, Sendable {
    public var id: String
    public var from: String
    public var to: String
    public var kind: String
    public var label: String?
    public var state: String

    public init(
        id: String, from: String, to: String, kind: String, label: String? = nil, state: String
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.kind = kind
        self.label = label
        self.state = state
    }
}

public nonisolated struct CanvasAgentIconSummary: Codable, Hashable, Sendable {
    public var packID: String
    public var iconID: String
    public var label: String

    public init(packID: String, iconID: String, label: String) {
        self.packID = packID
        self.iconID = iconID
        self.label = label
    }
}

public nonisolated struct CanvasAgentToolResult: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok
        case pendingApproval = "pending_approval"
    }

    public var status: Status
    public var message: String?
    public var ensemble: String?
    public var agentControl: String?
    public var callerNodeID: String?
    public var nodes: [CanvasAgentNodeSummary]?
    public var edges: [CanvasAgentEdgeSummary]?
    public var nodeID: String?
    public var edgeID: String?
    public var requestID: String?
    public var text: String?
    public var offset: Int?
    public var totalLength: Int?
    public var truncated: Bool?
    /// Icon matches from `icon_search`.
    public var icons: [CanvasAgentIconSummary]?
    /// `diagram_build`: created node ID per local spec id.
    public var createdNodes: [String: String]?
    /// A workspace-relative file path, for example an export.
    public var path: String?
    /// `send_message`: true when Rafu queued the message for the receiving
    /// agent. It does not mean the agent has read it.
    public var delivered: Bool?
    /// `terminal_create` with `link`: the new peer's `@mention` for `send_message`.
    public var mention: String?
    /// `terminal_create`, `terminal_start` and `terminal_send`: where the
    /// node's shell stands when the call returns. Same words as the node
    /// `state` in `ensemble_describe`: `running` or `stopped`. `stopped` means
    /// any line is queued, not typed.
    public var state: String?
    /// `agent_configure`: `in_place`, `resume` or `queued`.
    public var strategy: String?
    /// `agent_configure`: true when the agent's answer in the terminal names
    /// the new value. False is "not seen", not "failed".
    public var confirmed: Bool?
    /// `agent_configure`: the newest terminal lines after the change,
    /// scrubbed of secrets, at most 200 characters.
    public var readback: String?

    public init(status: Status = .ok, message: String? = nil) {
        self.status = status
        self.message = message
    }

    /// Encoded for the agent: snake_case keys, no pretty printing.
    public func agentJSON() -> Data? {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(self)
    }

    /// Keeps the agent-facing encoding under `maximumBytes`: titles shrink
    /// first, then trailing nodes and edges are dropped and `truncated` is set.
    public func bounded(maximumBytes: Int) -> CanvasAgentToolResult {
        func size(_ value: CanvasAgentToolResult) -> Int { value.agentJSON()?.count ?? .max }
        var value = self
        if size(value) <= maximumBytes { return value }
        for limit in [40, 16] {
            value.nodes = value.nodes?.map { node in
                var copy = node
                copy.title = CanvasAgentText.singleLine(node.title, limit: limit)
                copy.path = node.path.map { CanvasAgentText.singleLine($0, limit: limit * 2) }
                return copy
            }
            value.edges = value.edges?.map { edge in
                var copy = edge
                copy.label = edge.label.map { CanvasAgentText.singleLine($0, limit: limit) }
                return copy
            }
            if size(value) <= maximumBytes { return value }
        }
        value.truncated = true
        while size(value) > maximumBytes {
            if let edges = value.edges, !edges.isEmpty {
                value.edges = Array(edges.dropLast(max(1, edges.count / 4)))
            } else if let icons = value.icons, !icons.isEmpty {
                value.icons = Array(icons.dropLast(max(1, icons.count / 4)))
            } else if let nodes = value.nodes, !nodes.isEmpty {
                value.nodes = Array(nodes.dropLast(max(1, nodes.count / 4)))
            } else if let text = value.text, !text.isEmpty {
                value.text = String(text.unicodeScalars.prefix(text.unicodeScalars.count / 2))
            } else {
                break
            }
        }
        return value
    }
}

// MARK: MCP definitions

public nonisolated enum CanvasAgentToolCatalog {
    private static func property(
        _ type: String, _ description: String, _ extra: [String: Any] = [:]
    )
        -> [String: Any]
    {
        var value: [String: Any] = ["type": type, "description": description]
        for (key, item) in extra { value[key] = item }
        return value
    }

    private static var nodeID: [String: Any] {
        property("string", "A node ID from ensemble_describe.")
    }
    private static var near: [String: Any] {
        property(
            "string", "Optional node ID. The new node appears to the right of that node.")
    }
    private static var x: [String: Any] {
        property("number", "Optional board x of the new node's centre.")
    }
    private static var y: [String: Any] {
        property("number", "Optional board y of the new node's centre.")
    }
    private static var memberIDs: [String: Any] {
        property(
            "array", "Node IDs inside the frame.",
            ["items": ["type": "string"], "maxItems": CanvasAgentToolCall.maximumFrameMembers])
    }
    private static var title: [String: Any] {
        property("string", "Title, at most 120 characters.")
    }

    private static var commandLimits: String {
        "Typed as one line: at most \(CanvasAgentToolCall.maximumCommandArguments) arguments, \(CanvasAgentToolCall.maximumCommandArgumentBytes) bytes each, \(CanvasAgentToolCall.maximumCommandBytes) bytes in all, no control characters."
    }

    private static func schema(_ properties: [String: Any], required: [String] = [])
        -> [String: Any]
    {
        [
            "type": "object", "properties": properties, "required": required,
            "additionalProperties": false,
        ]
    }

    /// MCP `tools/list` entries for the orchestration tools.
    public static var definitions: [[String: Any]] {
        CanvasAgentTool.allCases.map { tool in
            let (description, inputSchema) = definition(for: tool)
            return ["name": tool.rawValue, "description": description, "inputSchema": inputSchema]
        }
    }

    private static func definition(for tool: CanvasAgentTool) -> (String, [String: Any]) {
        let textLimit = CanvasAgentToolCall.maximumTextBytes
        switch tool {
        case .ensembleDescribe:
            return (
                "Describe your Ensemble: every node (id, kind, title, rect, state, agent) and every edge (id, from, to, kind, label, state), plus your own node ID and the Agent control setting. Read-only.",
                schema([:])
            )
        case .noteRead:
            return (
                "Read a note's Markdown. Long notes return a slice; use offset and length (Unicode scalars) to page. Read-only.",
                schema(
                    [
                        "node_id": nodeID,
                        "offset": property("integer", "First scalar to return.", ["minimum": 0]),
                        "length": property(
                            "integer", "Scalars to return (at most 4000).",
                            ["minimum": 1, "maximum": CanvasAgentToolCall.maximumNoteSliceScalars]),
                    ], required: ["node_id"])
            )
        case .noteWrite:
            return (
                "Change a note. mode append adds at the end, prepend at the start, replace swaps the whole note, insert_after_heading adds the text below the named Markdown heading. A note holds at most 64 KiB.",
                schema(
                    [
                        "node_id": nodeID,
                        "text": property("string", "Markdown to write.", ["maxLength": textLimit]),
                        "mode": property(
                            "string", "How to write.",
                            ["enum": CanvasAgentNoteMode.allCases.map(\.rawValue)]),
                        "heading": property(
                            "string", "Heading text for insert_after_heading, without the # marks."),
                    ], required: ["node_id", "text", "mode"])
            )
        case .noteCreate:
            return (
                "Add a Markdown note to the Ensemble. Notes are shared memory between agents.",
                schema(
                    [
                        "title": title,
                        "markdown": property(
                            "string", "Initial Markdown.", ["maxLength": textLimit]),
                        "near": near, "x": x, "y": y,
                    ], required: ["title"])
            )
        case .nodeCreate:
            return (
                "Add a node. kind note/mermaid/text use text (a Mermaid diagram larger than 8000 by 8000 pt is not drawn; split it); file/image use a workspace-relative path; web uses a localhost URL; shape uses shape; service_icon uses pack_id and icon_id from icon_search plus label; frame uses title and member_ids. A terminal node is created stopped.",
                schema(
                    [
                        "kind": property(
                            "string", "Node kind.", ["enum": CanvasAgentToolCall.nodeKinds]),
                        "title": title,
                        "text": property(
                            "string", "Note Markdown, Mermaid source, or text.",
                            ["maxLength": textLimit]),
                        "path": property("string", "Workspace-relative file path."),
                        "url": property("string", "http(s) URL on localhost or 127.0.0.1."),
                        "shape": property(
                            "string", "Shape kind.", ["enum": CanvasAgentToolCall.shapes]),
                        "width": property("number", "Optional width (96–2000)."),
                        "height": property("number", "Optional height (64–2000)."),
                        "pack_id": property("string", "Icon pack ID from icon_search."),
                        "icon_id": property("string", "Icon ID from icon_search."),
                        "label": property("string", "Label under a service icon."),
                        "member_ids": memberIDs,
                        "near": near, "x": x, "y": y,
                    ], required: ["kind"])
            )
        case .nodeUpdate:
            return (
                "Rename, move or resize a node. x and y are the top-left corner in board units. A frame fits its members by itself: moving a frame moves its members, and its width and height are ignored. To change a frame's size, move its members.",
                schema(
                    [
                        "node_id": nodeID, "title": title,
                        "x": property("number", "New left edge."),
                        "y": property("number", "New top edge."),
                        "width": property("number", "New width (96–2000)."),
                        "height": property("number", "New height (64–2000)."),
                    ], required: ["node_id"])
            )
        case .nodeRemove:
            return (
                "Remove a node and its links; a terminal node also stops its process, with no second prompt. Always asks the user unless Agent control is Allow. Undoable.",
                schema(["node_id": nodeID], required: ["node_id"])
            )
        case .terminalCreate:
            return (
                "Add a terminal node. With agent (claude, codex, opencode, gemini, cursor, kimi, cline) or command (an argument array, never a shell string) Rafu starts the shell in the visible node and types that command. prompt gives claude or codex its first task. A prompt or command is typed as one line (see the limits on those arguments), so a long brief goes in a file or a note and the prompt names it. link true also adds a message link from your node to the new one: use it for every claude or codex peer, even one meant for the user (pause the link for quiet, do not skip it). Starting moves the user's view to the node. The reply has state: running means the shell is up and Rafu is typing the line; stopped means the node exists and the line is queued, not typed. Read state, then ensemble_describe and list_connections, before you tell the user an agent runs. Starting asks the user unless Agent control is Allow.",
                schema(
                    [
                        "title": title,
                        "cwd": property("string", "Workspace-relative starting folder."),
                        "agent": property(
                            "string", "Agent CLI to start.",
                            ["enum": CanvasAgentLaunch.executables.keys.sorted()]),
                        "command": property(
                            "array",
                            "Argument vector to run instead of an agent. \(commandLimits)",
                            [
                                "items": [
                                    "type": "string",
                                    "maxLength": CanvasAgentToolCall.maximumCommandArgumentBytes,
                                ],
                                "maxItems": CanvasAgentToolCall.maximumCommandArguments,
                            ]),
                        "prompt": property(
                            "string",
                            "First task for claude or codex, typed as one argument of the launch line: at most \(CanvasAgentToolCall.maximumCommandArgumentBytes) bytes, newlines become spaces. For a longer brief write a file or a note and pass a one-line prompt that names the path or note title and what to do with it.",
                            ["maxLength": CanvasAgentToolCall.maximumCommandArgumentBytes]),
                        "model": property(
                            "string",
                            "Optional model for claude (--model) or codex (-m), for example sonnet or gpt-5. Lowercase letters, digits, '.', '-', '_'."
                        ),
                        "effort": property(
                            "string",
                            "Optional effort for claude (--effort: low, medium, high, xhigh, max) or codex (model_reasoning_effort: low, medium, high).",
                            ["enum": ["low", "medium", "high", "xhigh", "max"]]),
                        "link": property(
                            "boolean",
                            "Also add a message link from your node to the new terminal, Paused until you call link_set_state live. Do this for a claude or codex peer; the link turns Live when both run an agent."
                        ),
                        "near": near, "x": x, "y": y,
                    ])
            )
        case .terminalStart:
            return (
                "Start the shell in a stopped terminal node and type any lines queued for it. Moves the user's view to the node. The reply has state (running or stopped); stopped means queued lines are still not typed. Asks the user unless Agent control is Allow.",
                schema(["node_id": nodeID], required: ["node_id"])
            )
        case .terminalSend:
            return (
                "Send work to a terminal node. text goes through a Live message link when one connects you, like send_message. Otherwise Rafu types it only into a terminal you created: text into an agent terminal, or command (an argument array) into a shell terminal. The reply has state: stopped means the line is queued, not typed. If Rafu says no agent is connected but one runs in that node, link it (edge_create kind message, then link_set_state live). Typing asks the user unless Agent control is Allow.",
                schema(
                    [
                        "node_id": nodeID,
                        "text": property(
                            "string",
                            "Task or one line of input, at most \(CanvasAgentToolCall.maximumPromptBytes) bytes. For a longer brief write a file or a note and send a one-line text that names it.",
                            ["maxLength": CanvasAgentToolCall.maximumPromptBytes]),
                        "command": property(
                            "array",
                            "Argument vector for a shell terminal you created. \(commandLimits)",
                            [
                                "items": ["type": "string"],
                                "maxItems": CanvasAgentToolCall.maximumCommandArguments,
                            ]),
                    ], required: ["node_id"])
            )
        case .edgeCreate:
            return (
                "Link two nodes. kind message links two terminals for agent messages and starts Paused; call link_set_state live to deliver messages. kind relationship is visual only.",
                schema(
                    [
                        "from": nodeID, "to": nodeID,
                        "kind": property(
                            "string", "Link kind.", ["enum": CanvasAgentToolCall.edgeKinds]),
                        "label": property("string", "Optional label, at most 120 characters."),
                    ], required: ["from", "to", "kind"])
            )
        case .edgeRemove:
            return (
                "Remove a link. Always asks the user unless Agent control is Allow. Undoable.",
                schema(
                    ["edge_id": property("string", "An edge ID from ensemble_describe.")],
                    required: ["edge_id"])
            )
        case .linkSetState:
            return (
                "Set a message link Live (messages pass) or Paused (nothing passes).",
                schema(
                    [
                        "edge_id": property("string", "A message edge ID."),
                        "state": property(
                            "string", "Link state.", ["enum": CanvasAgentToolCall.linkStates]),
                    ], required: ["edge_id", "state"])
            )
        case .mermaidSet:
            return (
                "Set the Mermaid source of a mermaid node. Rafu renders it natively up to 8000 by 8000 pt; a larger diagram shows its raw source, so split big diagrams into several smaller ones.",
                schema(
                    [
                        "node_id": nodeID,
                        "source": property("string", "Mermaid source.", ["maxLength": textLimit]),
                    ], required: ["node_id", "source"])
            )
        case .actionStatus:
            return (
                "Read the result of a call that returned pending_approval. Read-only.",
                schema(
                    ["request_id": property("string", "The request_id you received.")],
                    required: ["request_id"])
            )
        case .viewRender, .viewUpdate: return viewDefinition(for: tool)
        case .agentConfigure: return configureDefinition()
        default: return diagramDefinition(for: tool)
        }
    }

    private static func configureDefinition() -> (String, [String: Any]) {
        let efforts = CanvasAgentConfigureAgent.allCases.map {
            "\($0.rawValue): \($0.efforts.joined(separator: ", "))"
        }.joined(separator: "; ")
        let modes = CanvasAgentConfigureAgent.allCases.map {
            "\($0.rawValue): \($0.modes.joined(separator: ", "))"
        }.joined(separator: "; ")
        return (
            "Change the model, effort or mode of a claude or codex agent running in a terminal node, also in the middle of its conversation. Claude Code changes model and effort in place (Rafu types /model and /effort); a mode change, and every Codex change, uses strategy resume: the agent quits and resumes the same conversation with the new flags. Refused with agent_busy while the agent is mid-turn; pass queue true to run the change when the turn ends. The result has strategy (in_place, resume or queued), confirmed (the terminal showed the new value) and readback (the newest terminal lines, scrubbed). Say whether it was confirmed; never retry on your own. Only a terminal you created. Asks the user unless Agent control is Allow; a resume always asks.",
            schema(
                [
                    "node_id": nodeID,
                    "model": property(
                        "string",
                        "Model name or alias, for example sonnet, opus or gpt-5. Lowercase letters, digits, '.', '-', '_'; at most 64 characters."
                    ),
                    "effort": property(
                        "string", "Reasoning effort. \(efforts).",
                        ["enum": CanvasAgentConfigurePlan.allEfforts.sorted()]),
                    "mode": property(
                        "string", "Permission or sandbox mode (resume only). \(modes).",
                        ["enum": CanvasAgentConfigurePlan.allModes.sorted()]),
                    "strategy": property(
                        "string",
                        "in_place (Claude Code only) or resume. Default: in_place for Claude Code, resume for Codex.",
                        ["enum": CanvasAgentConfigureStrategy.allCases.map(\.rawValue)]),
                    "queue": property(
                        "boolean", "If the agent is mid-turn, run the change when the turn ends."),
                ], required: ["node_id"])
        )
    }

    private static func viewDefinition(for tool: CanvasAgentTool) -> (String, [String: Any]) {
        switch tool {
        case .viewRender:
            return (
                "Show a generated view on the Ensemble: a small native UI (cards, tables, charts, "
                    + "stats, file links, checklists) described as JSON. Put data in state and bind "
                    + "it. At most \(CanvasAgentToolCall.maximumViewBytes / 1_024) KiB of spec per "
                    + "call; add more with view_update patches. Asks the user unless Agent control "
                    + "is Allow. " + CanvasAgentViewVocabulary.text,
                schema(
                    [
                        "title": title, "near": near, "x": x, "y": y,
                        "spec": CanvasAgentViewVocabulary.specSchema,
                    ], required: ["spec"])
            )
        default:
            return (
                "Change a view. Give spec to replace it, patches (JSON Lines, one {op, path, value} "
                    + "per line against the current spec) to edit it, or reset true to restore its "
                    + "initial state. A changed spec resets the view's state.",
                schema(
                    [
                        "node_id": nodeID, "spec": CanvasAgentViewVocabulary.specSchema,
                        "patches": property(
                            "string", "JSON Lines of SpecStream patches.",
                            ["maxLength": CanvasAgentToolCall.maximumViewBytes]),
                        "reset": property("boolean", "Restore the view's initial state."),
                    ], required: ["node_id"])
            )
        }
    }

    private static func diagramDefinition(for tool: CanvasAgentTool) -> (String, [String: Any]) {
        switch tool {
        case .iconSearch:
            return (
                "Search the icon packs (Common, and AWS, Azure or Google Cloud packs the user imported) by name. Returns pack_id, icon_id and label for node_create kind service_icon or diagram_build. Read-only.",
                schema(
                    [
                        "query": property(
                            "string", "Words to search, for example queue or lambda."),
                        "limit": property(
                            "integer", "Matches to return (1–50).", ["minimum": 1, "maximum": 50]),
                    ], required: ["query"])
            )
        case .frameCreate:
            return (
                "Put nodes in a titled frame. The frame always fits its members: it grows, shrinks and moves when they do, and moving the frame moves its members. Undoable.",
                schema(
                    ["title": title, "member_ids": memberIDs], required: ["title", "member_ids"])
            )
        case .export:
            return (
                "Export the board, the selection or one frame to a file in the workspace exports folder. png takes scale, gif takes seconds and fps and shows dots moving along links. Returns the workspace-relative path. Asks the user unless Agent control is Allow.",
                schema(
                    [
                        "target": property(
                            "string", "What to export (default board).",
                            ["enum": CanvasAgentToolCall.exportTargets]),
                        "frame_id": property("string", "Frame node ID when target is frame."),
                        "format": property(
                            "string", "File format.", ["enum": CanvasAgentToolCall.exportFormats]),
                        "scale": property("number", "PNG scale (0.5–4, default 2)."),
                        "seconds": property("number", "GIF length (1–10, default 3)."),
                        "fps": property("integer", "GIF frames per second (1–30, default 12)."),
                    ], required: ["format"])
            )
        default:
            return (
                "Build a whole diagram in one undoable step (a frame adds a second step). spec.nodes: [{id, kind (service_icon, note, text or shape), label, pack_id, icon_id, shape}]; spec.edges: [{from, to, label}] using the local ids; spec.frame: optional frame title; spec.direction: right (default) or down. Rafu lays nodes out in layers: the longest chain on one line, branches beside it, and gaps wide enough for the edge labels. Keep labels short (a few words). Returns the created node IDs keyed by local id.",
                schema(
                    [
                        "spec": property(
                            "object", "Diagram spec.",
                            [
                                "properties": [
                                    "nodes": [
                                        "type": "array",
                                        "maxItems": CanvasAgentDiagramSpec.maximumNodes,
                                    ],
                                    "edges": [
                                        "type": "array",
                                        "maxItems": CanvasAgentDiagramSpec.maximumEdges,
                                    ],
                                    "frame": ["type": "string"],
                                    "direction": ["type": "string", "enum": ["right", "down"]],
                                ],
                                "required": ["nodes"],
                            ]),
                        "near": near, "x": x, "y": y,
                    ], required: ["spec"])
            )
        }
    }
}

// MARK: Views

/// One approval line for a view spec: the element count and up to eight
/// distinct component types, sorted. Never a prop value or any other text
/// from the spec.
public nonisolated enum CanvasAgentViewSummary {
    public static let maximumTypes = 8

    public static func line(specJSON: String) -> String {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(specJSON.utf8))
                as? [String: Any],
            let elements = object["elements"] as? [String: Any]
        else { return "invalid spec" }
        let types = Set(
            elements.values.compactMap { ($0 as? [String: Any])?["type"] as? String }
                .filter { $0.utf8.count <= 40 && CanvasAgentText.validIdentifier($0) })
        let shown = types.sorted().prefix(maximumTypes)
        let noun = elements.count == 1 ? "element" : "elements"
        var line = "\(elements.count) \(noun)"
        if !shown.isEmpty { line += "; " + shown.joined(separator: ", ") }
        if types.count > maximumTypes { line += ", …" }
        return line
    }
}

/// Parses and bounds the `spec` argument of `view_render` / `view_update`.
/// RafuCore checks the shape and size only; the app decodes the spec and
/// validates it against the Rafu catalog. Error reasons are fixed text and
/// numbers, never spec content.
public nonisolated enum CanvasAgentViewSpec {
    static let shapeReason = "spec must be an object with root (string) and elements (object)"

    static func tooLargeReason(bytes: Int) -> String {
        "spec is \(CanvasAgentShellRefusal.grouped(bytes)) bytes; at most "
            + "\(CanvasAgentToolCall.maximumViewBytes / 1_024) KiB per call; "
            + "add more with view_update patches"
    }

    /// The canonical text of a spec object: sorted keys, no escaped slashes.
    public static func canonicalText(_ value: Any) throws(CanvasAgentToolError) -> String {
        guard let object = value as? [String: Any], object["root"] is String,
            let elements = object["elements"] as? [String: Any]
        else { throw .invalidArgumentReason(key: "spec", reason: shapeReason) }
        guard elements.count <= CanvasAgentToolCall.maximumViewElements else {
            throw .invalidArgumentReason(
                key: "spec",
                reason: "spec has \(elements.count) elements; at most "
                    + "\(CanvasAgentToolCall.maximumViewElements)")
        }
        guard !containsForbiddenKey(object, depth: 0) else {
            throw .invalidArgumentReason(key: "spec", reason: "spec contains a forbidden key")
        }
        guard JSONSerialization.isValidJSONObject(object),
            let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { throw .invalidArgumentReason(key: "spec", reason: shapeReason) }
        guard data.count <= CanvasAgentToolCall.maximumViewBytes else {
            throw .invalidArgumentReason(key: "spec", reason: tooLargeReason(bytes: data.count))
        }
        return text
    }

    /// `__proto__` anywhere, or nesting deeper than 64 levels, is refused.
    private static func containsForbiddenKey(_ value: Any, depth: Int) -> Bool {
        if depth > 64 { return true }
        if let object = value as? [String: Any] {
            return object.contains { key, item in
                key == "__proto__" || containsForbiddenKey(item, depth: depth + 1)
            }
        }
        if let array = value as? [Any] {
            return array.contains { containsForbiddenKey($0, depth: depth + 1) }
        }
        return false
    }

    /// Bounds the `patches` text: bytes, line count, and each non-blank line
    /// starts with `{`. The app applies and validates the patches.
    static func validatePatches(_ text: String) throws(CanvasAgentToolError) {
        guard text.utf8.count <= CanvasAgentToolCall.maximumViewBytes else {
            throw .invalidArgumentReason(
                key: "patches",
                reason: "patches are \(CanvasAgentShellRefusal.grouped(text.utf8.count)) bytes; "
                    + "at most \(CanvasAgentToolCall.maximumViewBytes / 1_024) KiB per call")
        }
        guard !text.contains("\0") else { throw .invalidArgument("patches") }
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { throw .invalidArgument("patches") }
        guard lines.count <= CanvasAgentToolCall.maximumViewPatchLines else {
            throw .invalidArgumentReason(
                key: "patches",
                reason: "\(lines.count) lines; at most \(CanvasAgentToolCall.maximumViewPatchLines)"
            )
        }
        guard lines.allSatisfy({ $0.hasPrefix("{") }) else {
            throw .invalidArgumentReason(
                key: "patches", reason: "each line must be one JSON object {op, path, value}")
        }
    }
}

// MARK: Diagrams

/// A small diagram description that `diagram_build` lays out in one step.
public nonisolated struct CanvasAgentDiagramSpec: Codable, Hashable, Sendable {
    public struct Node: Codable, Hashable, Sendable {
        public var id: String
        public var kind: String
        public var label: String
        public var packID: String?
        public var iconID: String?
        public var shape: String?

        public init(
            id: String, kind: String = "service_icon", label: String, packID: String? = nil,
            iconID: String? = nil, shape: String? = nil
        ) {
            self.id = id
            self.kind = kind
            self.label = label
            self.packID = packID
            self.iconID = iconID
            self.shape = shape
        }
    }

    public struct Edge: Codable, Hashable, Sendable {
        public var from: String
        public var to: String
        public var label: String?

        public init(from: String, to: String, label: String? = nil) {
            self.from = from
            self.to = to
            self.label = label
        }
    }

    public var nodes: [Node]
    public var edges: [Edge]
    public var frame: String?
    public var direction: String?

    public static let maximumNodes = 40
    public static let maximumEdges = 80
    public static let nodeKinds = ["service_icon", "note", "text", "shape"]

    public init(nodes: [Node], edges: [Edge] = [], frame: String? = nil, direction: String? = nil) {
        self.nodes = nodes
        self.edges = edges
        self.frame = frame
        self.direction = direction
    }

    private static func text(_ item: [String: Any], _ key: String) throws(CanvasAgentToolError)
        -> String?
    {
        guard let value = item[key] else { return nil }
        guard let string = value as? String else { throw .invalidArgument("spec") }
        return string
    }

    static func parse(_ object: [String: Any]) throws(CanvasAgentToolError)
        -> CanvasAgentDiagramSpec
    {
        let keys: Set<String> = ["nodes", "edges", "frame", "direction"]
        guard Set(object.keys).isSubset(of: keys),
            let rawNodes = object["nodes"] as? [Any], rawNodes.count <= maximumNodes
        else { throw .invalidArgument("spec") }
        var rawEdges: [Any] = []
        if let value = object["edges"] {
            guard let list = value as? [Any], list.count <= maximumEdges else {
                throw .invalidArgument("spec")
            }
            rawEdges = list
        }
        let nodeKeys: Set<String> = ["id", "kind", "label", "pack_id", "icon_id", "shape"]
        var nodes: [Node] = []
        for raw in rawNodes {
            guard let item = raw as? [String: Any], Set(item.keys).isSubset(of: nodeKeys) else {
                throw .invalidArgument("spec")
            }
            guard let id = try text(item, "id"), let label = try text(item, "label") else {
                throw .invalidArgument("spec")
            }
            let kind = try text(item, "kind")?.lowercased() ?? "service_icon"
            let packID = try text(item, "pack_id")
            let iconID = try text(item, "icon_id")
            let shape = try text(item, "shape")?.lowercased()
            nodes.append(
                Node(
                    id: id, kind: kind, label: label, packID: packID, iconID: iconID, shape: shape)
            )
        }
        var edges: [Edge] = []
        for raw in rawEdges {
            guard let item = raw as? [String: Any],
                Set(item.keys).isSubset(of: ["from", "to", "label"])
            else { throw .invalidArgument("spec") }
            guard let from = try text(item, "from"), let to = try text(item, "to") else {
                throw .invalidArgument("spec")
            }
            let label = try text(item, "label")
            edges.append(Edge(from: from, to: to, label: label))
        }
        let frame = try text(object, "frame")
        let direction = try text(object, "direction")?.lowercased()
        return CanvasAgentDiagramSpec(
            nodes: nodes, edges: edges, frame: frame, direction: direction)
    }

    public func validate() throws(CanvasAgentToolError) {
        guard !nodes.isEmpty, nodes.count <= Self.maximumNodes, edges.count <= Self.maximumEdges
        else { throw .invalidArgument("spec") }
        var ids = Set<String>()
        for node in nodes {
            guard !node.id.isEmpty, node.id.utf8.count <= 64,
                !CanvasAgentText.hasControl(node.id), ids.insert(node.id).inserted,
                Self.nodeKinds.contains(node.kind), CanvasAgentText.validTitle(node.label)
            else { throw .invalidArgument("spec.nodes") }
            if node.kind == "service_icon" {
                guard let pack = node.packID, let icon = node.iconID,
                    CanvasAgentText.validIdentifier(pack), CanvasAgentText.validIdentifier(icon)
                else { throw .invalidArgument("spec.nodes") }
            } else if node.packID != nil || node.iconID != nil {
                throw .invalidArgument("spec.nodes")
            }
            if let shape = node.shape, !CanvasAgentToolCall.shapes.contains(shape) {
                throw .invalidArgument("spec.nodes")
            }
        }
        for edge in edges {
            guard ids.contains(edge.from), ids.contains(edge.to), edge.from != edge.to else {
                throw .invalidArgument("spec.edges")
            }
            if let label = edge.label, !CanvasAgentText.validTitle(label) {
                throw .invalidArgument("spec.edges")
            }
        }
        if let frame, !CanvasAgentText.validTitle(frame) { throw .invalidArgument("spec.frame") }
        if let direction, direction != "right", direction != "down" {
            throw .invalidArgument("spec.direction")
        }
    }
}

public nonisolated struct CanvasAgentRect: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}
