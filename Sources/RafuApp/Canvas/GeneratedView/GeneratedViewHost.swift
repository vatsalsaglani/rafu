import Foundation

/// What a view creator needs from the card implementation (jr-4a). The MCP
/// and voice paths (jr-4c) call only this. Until jr-4a installs a host, the
/// registry holds nil and callers answer "views are not available".
@MainActor
protocol GeneratedViewHost: AnyObject {
    /// Decodes and validates against `RafuCatalog.rafu`. `.failure` carries the
    /// validator's message (fixed vocabulary, ids and types only) for the agent.
    func validate(specJSON: String) -> Result<GeneratedViewSummary, GeneratedViewError>
    /// One board undo step. Returns the new card id.
    func create(
        specJSON: String, title: String, rect: CanvasRect,
        provenance: CanvasGeneratedViewProvenance, on board: CanvasBoardState
    ) throws -> CanvasCardID
    /// One board undo step. `.spec` and `.patches` reset the state; `.reset`
    /// only resets it.
    func update(
        _ card: CanvasCardID, change: GeneratedViewChange,
        provenance: CanvasGeneratedViewProvenance, on board: CanvasBoardState
    ) async throws -> GeneratedViewSummary
    /// Voice streaming: creates the card at once as a skeleton and returns a
    /// handle that accepts argument text deltas. `finish(specJSON:)` validates
    /// and writes the final spec and provenance; an invalid final spec removes
    /// the card.
    func beginStreaming(
        title: String, rect: CanvasRect, provenance: CanvasGeneratedViewProvenance,
        on board: CanvasBoardState
    ) throws -> any GeneratedViewStreamHandle
}

/// How `GeneratedViewHost.update` changes a view.
nonisolated enum GeneratedViewChange: Sendable, Equatable {
    /// Replace the whole spec (canonical JSON text).
    case spec(String)
    /// JSONL SpecStream patches against the current spec.
    case patches(String)
    /// Restore the view's initial state; the spec stays.
    case reset
}

/// What a create or update reports back. Counts and component types only.
nonisolated struct GeneratedViewSummary: Sendable, Equatable {
    var elementCount: Int
    /// Distinct component types, sorted, at most 8.
    var types: [String]
    var warnings: Int
}

/// Why a view call failed. Messages carry fixed text, ids and types, never
/// prop values or state.
nonisolated enum GeneratedViewError: Error, Sendable, Equatable {
    /// The validator's text.
    case invalidSpec(String)
    case tooLarge(bytes: Int)
    /// The board already holds `CanvasLimits.generatedViewCards` views.
    case capacity
    /// The node is not a generated view.
    case notAView
    /// No host is registered yet.
    case unavailable
}

/// A view that fills while the voice backend streams its arguments.
@MainActor
protocol GeneratedViewStreamHandle: AnyObject {
    var cardID: CanvasCardID { get }
    func push(_ argumentsDelta: String)
    func finish(specJSON: String) async -> Result<GeneratedViewSummary, GeneratedViewError>
    func cancel()
}

/// Where the card implementation installs its host. One per process.
@MainActor
final class GeneratedViewHostRegistry {
    static let shared = GeneratedViewHostRegistry()
    var host: (any GeneratedViewHost)?
}

/// Fixed, user-visible text for the view tools.
nonisolated enum GeneratedViewCopy {
    static let unavailable = "Views are not available in this version of Rafu."
}
