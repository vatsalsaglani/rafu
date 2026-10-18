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
    case headingNotFound
    case noteTooLarge
    case textTooLarge(kilobytes: Int)

    public var message: String {
        switch self {
        case .unknownTool: "Unknown Ensemble tool."
        case .unexpectedArgument(let key): "Unexpected argument \"\(key)\"."
        case .missingArgument(let key): "Missing argument \"\(key)\"."
        case .invalidArgument(let key): "Invalid value for \"\(key)\"."
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
    case appOpen = "app_open"
    case appInspect = "app_inspect"
    case mermaidSet = "mermaid_set"
    case actionStatus = "action_status"
    case iconSearch = "icon_search"
    case frameCreate = "frame_create"
    case export = "export"
    case diagramBuild = "diagram_build"

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
        case .appOpen: "Open an app"
        case .appInspect: "Inspect an app"
        case .mermaidSet: "Change a diagram"
        case .actionStatus: "Read an action status"
        case .iconSearch: "Search icons"
        case .frameCreate: "Add a frame"
        case .export: "Export to a file"
        case .diagramBuild: "Build a diagram"
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
    public var state: String?
    public var bundleID: String?
    public var appName: String?
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

    public init(tool: CanvasAgentTool) { self.tool = tool }

    public static let nodeKinds = [
        "note", "terminal", "file", "image", "web", "app", "mermaid", "shape", "text",
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
    public static let maximumNoteSliceScalars = 4_000

    /// The risk of the call itself. `terminal_send` into a live message link is
    /// downgraded by the app, which knows the link state.
    public var risk: CanvasAgentRisk {
        switch tool {
        case .ensembleDescribe, .noteRead, .appInspect, .actionStatus, .iconSearch: .read
        case .nodeRemove, .edgeRemove, .terminalStart, .terminalSend, .appOpen, .export:
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
        if let command { add("Command", CanvasAgentShell.commandLine(command)) }
        add("State", state)
        add("App", bundleID ?? appName)
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
                "kind", "title", "text", "path", "url", "bundle_id", "app_name", "shape",
                "width", "height", "pack_id", "icon_id", "label", "member_ids",
            ])
        case .nodeUpdate: return ["node_id", "title", "x", "y", "width", "height"]
        case .nodeRemove, .terminalStart, .appInspect: return ["node_id"]
        case .terminalCreate:
            return placement.union(["title", "cwd", "agent", "command", "prompt"])
        case .terminalSend: return ["node_id", "text", "command"]
        case .edgeCreate: return ["from", "to", "kind", "label"]
        case .edgeRemove: return ["edge_id"]
        case .linkSetState: return ["edge_id", "state"]
        case .appOpen: return placement.union(["bundle_id", "app_name"])
        case .mermaidSet: return ["node_id", "source"]
        case .actionStatus: return ["request_id"]
        case .iconSearch: return ["query", "limit"]
        case .frameCreate: return ["title", "member_ids"]
        case .export: return ["target", "frame_id", "format", "scale", "seconds", "fps"]
        case .diagramBuild: return placement.union(["spec"])
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
        call.state = try string("state")?.lowercased()
        call.bundleID = try string("bundle_id")
        call.appName = try string("app_name")
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
            guard let object = value as? [String: Any] else { throw .invalidArgument("spec") }
            call.diagram = try CanvasAgentDiagramSpec.parse(object)
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
            throw .invalidArgument(tool == .mermaidSet ? "source" : "text")
        }
        if let heading, heading.utf8.count > 200 || heading.contains("\n") {
            throw .invalidArgument("heading")
        }
        if let prompt,
            prompt.isEmpty || prompt.utf8.count > Self.maximumPromptBytes || prompt.contains("\0")
        {
            throw .invalidArgument("prompt")
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
        if let command, CanvasAgentShell.commandLine(command) == nil {
            throw .invalidArgument("command")
        }
        if let bundleID, !CanvasAgentText.validBundleID(bundleID) {
            throw .invalidArgument("bundle_id")
        }
        if let appName,
            appName.isEmpty || appName.unicodeScalars.count > 100 || appName.contains("/")
                || !CanvasAgentText.validTitle(appName)
        {
            throw .invalidArgument("app_name")
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
        if let mode, CanvasAgentNoteMode(rawValue: mode) == nil { throw .invalidArgument("mode") }
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
    }

    private func validateRequirements() throws(CanvasAgentToolError) {
        func require(_ value: Any?, _ key: String) throws(CanvasAgentToolError) {
            if value == nil { throw .missingArgument(key) }
        }
        switch tool {
        case .ensembleDescribe: break
        case .noteRead, .nodeRemove, .terminalStart, .appInspect: try require(nodeID, "node_id")
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
        case .terminalSend:
            try require(nodeID, "node_id")
            guard (text == nil) != (command == nil) else { throw .missingArgument("text") }
            if let text, text.isEmpty || text.utf8.count > Self.maximumPromptBytes {
                throw .invalidArgument("text")
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
        case .appOpen:
            guard bundleID != nil || appName != nil else { throw .missingArgument("bundle_id") }
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
        }
    }

    private func validateNodeCreate() throws(CanvasAgentToolError) {
        guard let kind else { throw .missingArgument("kind") }
        guard Self.nodeKinds.contains(kind) else { throw .invalidArgument("kind") }
        switch kind {
        case "file", "image": if path == nil { throw .missingArgument("path") }
        case "web": if url == nil { throw .missingArgument("url") }
        case "app":
            guard bundleID != nil || appName != nil else { throw .missingArgument("bundle_id") }
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

    public static func validBundleID(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_")
        return !value.isEmpty && value.utf8.count <= 255
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
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

    /// One shell line from an argument vector, or nil when the vector is empty,
    /// too long, or contains control characters. Each element is quoted, so
    /// no element can add a pipe, redirect, substitution or second command.
    public static func commandLine(_ argv: [String]) -> String? {
        guard let first = argv.first, !first.isEmpty,
            argv.count <= CanvasAgentToolCall.maximumCommandArguments,
            argv.allSatisfy({ !CanvasAgentText.hasControl($0) && $0.utf8.count <= 1_024 })
        else { return nil }
        let line = argv.map(quote).joined(separator: " ")
        guard line.utf8.count <= CanvasAgentToolCall.maximumCommandBytes else { return nil }
        return line
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

    /// Claude Code and Codex accept an initial task as one positional argument
    /// and stay interactive.
    public static func acceptsPrompt(_ agent: String) -> Bool {
        agent == "claude" || agent == "codex"
    }

    /// The argument vector that starts the agent with an optional first task.
    /// Control characters in the task become spaces so it stays one line.
    public static func argv(agent: String, prompt: String?) -> [String]? {
        guard let executable = executable(for: agent) else { return nil }
        guard let prompt else { return [executable] }
        guard acceptsPrompt(agent) else { return nil }
        let line = CanvasAgentText.singleLine(prompt, limit: CanvasAgentToolCall.maximumPromptBytes)
            .trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? [executable] : [executable, line]
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
                "Add a node. kind note/mermaid/text use text; file/image use a workspace-relative path; web uses a localhost URL; app uses bundle_id or app_name (the app is not launched; use app_open); shape uses shape; service_icon uses pack_id and icon_id from icon_search plus label; frame uses title and member_ids. A terminal node is created stopped.",
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
                        "bundle_id": property("string", "macOS bundle identifier."),
                        "app_name": property("string", "App name, for example Simulator."),
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
                "Rename, move or resize a node. x and y are the top-left corner in board units.",
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
                "Remove a node and its links. Always asks the user unless Agent control is Allow. Undoable.",
                schema(["node_id": nodeID], required: ["node_id"])
            )
        case .terminalCreate:
            return (
                "Add a terminal node. With agent (claude, codex, opencode, gemini, cursor, kimi, cline) or command (an argument array, never a shell string) Rafu starts the shell in the visible node and types that command. prompt gives claude or codex its first task. Starting asks the user unless Agent control is Allow.",
                schema(
                    [
                        "title": title,
                        "cwd": property("string", "Workspace-relative starting folder."),
                        "agent": property(
                            "string", "Agent CLI to start.",
                            ["enum": CanvasAgentLaunch.executables.keys.sorted()]),
                        "command": property(
                            "array", "Argument vector to run instead of an agent.",
                            [
                                "items": ["type": "string"],
                                "maxItems": CanvasAgentToolCall.maximumCommandArguments,
                            ]),
                        "prompt": property("string", "First task for claude or codex."),
                        "near": near, "x": x, "y": y,
                    ])
            )
        case .terminalStart:
            return (
                "Start the shell in a stopped terminal node. Asks the user unless Agent control is Allow.",
                schema(["node_id": nodeID], required: ["node_id"])
            )
        case .terminalSend:
            return (
                "Send work to a terminal node. text goes through a Live message link when one connects you, like send_message. Otherwise Rafu types it only into a terminal you created: text into an agent terminal, or command (an argument array) into a shell terminal. Typing asks the user unless Agent control is Allow.",
                schema(
                    [
                        "node_id": nodeID,
                        "text": property(
                            "string", "Task or one line of input.",
                            ["maxLength": CanvasAgentToolCall.maximumPromptBytes]),
                        "command": property(
                            "array", "Argument vector for a shell terminal you created.",
                            ["items": ["type": "string"]]),
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
        case .appOpen:
            return (
                "Open a macOS app and show it in an app node (reuses a node for the same app). Asks the user unless Agent control is Allow.",
                schema([
                    "bundle_id": property(
                        "string", "Bundle identifier, for example com.apple.Safari."),
                    "app_name": property("string", "App name, for example Simulator."),
                    "near": near, "x": x, "y": y,
                ])
            )
        case .appInspect:
            return (
                "Read the Accessibility summary of the app window docked in an app node, to verify what the app shows. Needs the user's Accessibility permission. Read-only.",
                schema(["node_id": nodeID], required: ["node_id"])
            )
        case .mermaidSet:
            return (
                "Set the Mermaid source of a mermaid node. Rafu renders it natively.",
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
        default: return diagramDefinition(for: tool)
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
                "Put nodes in a titled frame. Moving the frame moves its members. Undoable.",
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
                "Build a whole diagram in one undoable step (a frame adds a second step). spec.nodes: [{id, kind (service_icon, note, text or shape), label, pack_id, icon_id, shape}]; spec.edges: [{from, to, label}] using the local ids; spec.frame: optional frame title; spec.direction: right (default) or down. Rafu lays nodes out in layers and returns the created node IDs keyed by local id.",
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

/// A layered layout: each node goes one layer after its furthest
/// predecessor. Cycles are broken in node order. Pure and deterministic.
public nonisolated enum CanvasAgentDiagramLayout {
    public static let gap = 80.0
    public static let rowGap = 48.0

    public static func size(of node: CanvasAgentDiagramSpec.Node) -> (width: Double, height: Double)
    {
        switch node.kind {
        case "service_icon": (160, 128)
        case "note": (260, 180)
        default: (200, 120)
        }
    }

    /// Layer index per node id. Ready nodes are placed in rounds; when a
    /// cycle leaves no ready node, the earliest remaining node is placed.
    public static func layers(_ spec: CanvasAgentDiagramSpec) -> [String: Int] {
        var incoming: [String: Set<String>] = [:]
        for edge in spec.edges where edge.from != edge.to {
            incoming[edge.to, default: []].insert(edge.from)
        }
        var remaining = spec.nodes.map(\.id)
        var layer: [String: Int] = [:]
        while !remaining.isEmpty {
            let open = Set(remaining)
            var ready = remaining.filter { (incoming[$0] ?? []).isDisjoint(with: open) }
            if ready.isEmpty { ready = [remaining[0]] }
            for id in ready {
                layer[id] = (incoming[id] ?? []).compactMap { layer[$0] }.map { $0 + 1 }.max() ?? 0
            }
            let placed = Set(ready)
            remaining.removeAll { placed.contains($0) }
        }
        return layer
    }

    /// Top-left rects relative to the origin, keyed by local node id.
    public static func rects(
        for spec: CanvasAgentDiagramSpec, originX: Double = 0, originY: Double = 0
    ) -> [String: CanvasAgentRect] {
        let layer = layers(spec)
        let down = spec.direction == "down"
        var columns: [Int: [CanvasAgentDiagramSpec.Node]] = [:]
        for node in spec.nodes { columns[layer[node.id] ?? 0, default: []].append(node) }
        var result: [String: CanvasAgentRect] = [:]
        var along = 0.0
        for index in columns.keys.sorted() {
            var across = 0.0
            var thickness = 0.0
            for node in columns[index] ?? [] {
                let size = size(of: node)
                result[node.id] =
                    down
                    ? CanvasAgentRect(
                        x: originX + across, y: originY + along, width: size.width,
                        height: size.height)
                    : CanvasAgentRect(
                        x: originX + along, y: originY + across, width: size.width,
                        height: size.height)
                across += (down ? size.width : size.height) + rowGap
                thickness = max(thickness, down ? size.height : size.width)
            }
            along += thickness + gap
        }
        return result
    }

    /// The bounding rect of `rects` grown by `padding` (more at the top for a
    /// frame title).
    public static func bounds(_ rects: [CanvasAgentRect], padding: Double = 40)
        -> CanvasAgentRect?
    {
        guard let first = rects.first else { return nil }
        var minX = first.x
        var minY = first.y
        var maxX = first.x + first.width
        var maxY = first.y + first.height
        for rect in rects.dropFirst() {
            minX = min(minX, rect.x)
            minY = min(minY, rect.y)
            maxX = max(maxX, rect.x + rect.width)
            maxY = max(maxY, rect.y + rect.height)
        }
        return CanvasAgentRect(
            x: minX - padding, y: minY - padding * 1.5, width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2.5)
    }
}
