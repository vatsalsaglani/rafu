import Foundation

/// The only seam lane 2 (LSP / language intelligence) needs into
/// `WorkspaceSession` and `EditorDocument`. `WorkspaceSession` owns exactly
/// one instance and calls these lifecycle hooks around workspace
/// open/close/replace and document open/close; lane 2 never edits
/// `WorkspaceSession.swift` or the `Navigation/` types directly, only this
/// file (and the rest of `Sources/RafuApp/LanguageIntelligence/`).
///
/// This is a stub after the increment-0 contract commit: every method body
/// is empty. A real implementation subscribes to a document's
/// `EditorDocument.editDeltas()` stream from inside `documentDidOpen(_:)` to
/// drive incremental reparsing and/or LSP `didChange` notifications, and
/// tears that subscription down in `documentDidClose(_:)`.
@MainActor
final class LanguageIntelligenceCoordinator {
    func workspaceDidOpen(root: URL) {}

    func workspaceDidClose() {}

    func documentDidOpen(_ document: EditorDocument) {}

    func documentDidClose(_ document: EditorDocument) {}
}
