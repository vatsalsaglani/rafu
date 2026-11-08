import Foundation
import RafuCore

/// `view_render` and `view_update`: the MCP side of generated view cards.
/// The approval, the activity log, the agent badge and the "· Undo" notice
/// come from `CanvasAgentActions.handle` / `perform`, like every other tool;
/// the card work is the installed `GeneratedViewHost`.
extension CanvasAgentActions {
    /// A view card's size when the call gives none.
    static let viewDefaultSize = (width: 420.0, height: 300.0)

    static func viewRender(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) throws
        -> CanvasBridgeResponse
    {
        guard let host = GeneratedViewHostRegistry.shared.host else {
            return .init(error: GeneratedViewCopy.unavailable)
        }
        guard let spec = call.viewSpec else { throw CanvasAgentToolError.missingArgument("spec") }
        var sized = call
        sized.width = call.width ?? viewDefaultSize.width
        sized.height = call.height ?? viewDefaultSize.height
        let rect = placement(sized, kind: "view", caller: caller)
        let title = GeneratedViewActions.title(call.title ?? "View")
        let id: CanvasCardID
        do {
            id = try host.create(
                specJSON: spec, title: title, rect: rect,
                provenance: viewProvenance(call, caller: caller), on: caller.board)
        } catch let error as GeneratedViewError {
            throw toolError(error)
        }
        let count = (try? host.validate(specJSON: spec).get())?.elementCount ?? 0
        let noun = count == 1 ? "element" : "elements"
        var result = CanvasAgentToolResult(message: "Added view \"\(title)\" (\(count) \(noun)).")
        result.nodeID = id.rawValue.uuidString
        return .init(toolResult: result)
    }

    static func viewUpdate(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller) async throws
        -> CanvasBridgeResponse
    {
        guard let host = GeneratedViewHostRegistry.shared.host else {
            return .init(error: GeneratedViewCopy.unavailable)
        }
        let board = caller.board
        guard let id = call.nodeID.flatMap(UUID.init(uuidString:)),
            let card = board.cards.first(where: { $0.id.rawValue == id })
        else { throw CanvasAgentToolError.invalidArgument("node_id") }
        let change: GeneratedViewChange
        if let spec = call.viewSpec {
            change = .spec(spec)
        } else if let patches = call.viewPatches {
            change = .patches(patches)
        } else if call.reset == true {
            change = .reset
        } else {
            throw CanvasAgentToolError.missingArgument("spec")
        }
        let before = card.content
        do {
            _ = try await host.update(
                card.id, change: change, provenance: viewProvenance(call, caller: caller),
                on: board)
        } catch let error as GeneratedViewError {
            throw toolError(error)
        }
        let after = board.cards.first { $0.id == card.id }?.content
        let message: String
        switch change {
        case .reset: message = "View \"\(card.title)\" reset to its initial state."
        case .spec, .patches:
            message =
                after == before
                ? "No change: view \"\(card.title)\" already shows this spec."
                : "View \"\(card.title)\" updated."
        }
        var result = CanvasAgentToolResult(message: message)
        result.nodeID = card.id.rawValue.uuidString
        return .init(toolResult: result)
    }

    /// Who made the view and how the call was admitted. Names only.
    static func viewProvenance(_ call: CanvasAgentToolCall, caller: CanvasAgentCaller)
        -> CanvasGeneratedViewProvenance
    {
        let admission: String =
            if caller.provider == "voice" {
                "voice"
            } else {
                caller.board.agentControlMode == .allow ? "allow" : "ask"
            }
        let now = Date()
        return CanvasGeneratedViewProvenance(
            creator: CanvasAgentNoticeText.vendor(provider: caller.provider),
            provider: String(caller.provider.prefix(16)), createdAt: now,
            updatedAt: call.tool == .viewUpdate ? now : nil,
            promptSummary: call.title.map { CanvasAgentText.singleLine($0, limit: 200) },
            admission: admission, journal: [])
    }

    /// The text an agent sees. Validator text carries codes, element keys and
    /// types, never prop values; it is bounded to one line of 1,000 bytes.
    static func toolError(_ error: GeneratedViewError) -> Error {
        switch error {
        case .invalidSpec(let text):
            return CanvasAgentToolError.invalidArgumentReason(
                key: "spec", reason: CanvasAgentText.singleLine(text, limit: 1_000))
        case .tooLarge(let bytes):
            return CanvasAgentToolError.invalidArgumentReason(
                key: "spec", reason: GeneratedViewBudget.reason(bytes: bytes))
        case .capacity: return CanvasError.capacity
        case .notAView: return CanvasAgentToolError.invalidArgument("node_id")
        case .unavailable:
            return CanvasAgentToolError.invalidArgumentReason(
                key: "spec", reason: GeneratedViewCopy.unavailable)
        }
    }
}
