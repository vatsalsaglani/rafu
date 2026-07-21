import Foundation

/// A terminal session's color TAG (terminal-manager.md T-D) — one of a
/// small set of THEME palette tokens, never a raw hex value, so switching
/// themes restyles every tagged session automatically. Deliberately no
/// SwiftUI import: resolving a case to an actual `Color` is a view-layer
/// concern (`RafuThemePalette.color(for:)` in `RafuTheme.swift`), keeping
/// this enum headless-testable and reusable from the model layer. Never
/// meaning by color alone (AGENTS) — always shown paired with the session's
/// name/status text (panel dot beside the status glyph, tab strip's leading
/// stripe beside the label). Not persisted: terminal sessions never
/// restore across relaunch (ADR 0004), so neither does their color — see
/// `WorkspaceSession.setTerminalSessionColor(_:_:)`.
nonisolated enum TerminalSessionColor: String, CaseIterable, Codable, Sendable {
    case accent
    case info
    case success
    case warning
    case error
    case muted

    var displayName: String {
        switch self {
        case .accent: "Accent"
        case .info: "Blue"
        case .success: "Green"
        case .warning: "Amber"
        case .error: "Red"
        case .muted: "Gray"
        }
    }
}
