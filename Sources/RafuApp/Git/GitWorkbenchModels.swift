import Foundation

enum GitInspectorSection: String, CaseIterable, Sendable {
    case changes
    case history

    var title: String { rawValue.capitalized }
}

/// Persisted (`@AppStorage`) Source Control Changes presentation.
enum GitChangesViewMode: String, CaseIterable, Sendable {
    case flat
    case tree
}

struct GitOpenDiff: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let diff: GitFileDiff
    let scope: GitDiffScope

    init(title: String, subtitle: String, diff: GitFileDiff, identity: String, scope: GitDiffScope)
    {
        id = identity
        self.title = title
        self.subtitle = subtitle
        self.diff = diff
        self.scope = scope
    }
}
