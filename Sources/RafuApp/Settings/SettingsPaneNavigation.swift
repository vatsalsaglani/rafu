import SwiftUI

/// The seven Settings panes, in toolbar order.
///
/// The standard `Settings` scene hosts them as a `TabView`, which macOS
/// renders as toolbar-style panes (symbol above label). Lifted out of
/// `RafuSettingsView`'s view builder so the set is assertable from a test.
/// `nonisolated` on the primary declaration: the pane list is inert data with
/// no UI of its own, and the target's default `MainActor` isolation would
/// otherwise make even a key path to `title` unformable from a test.
nonisolated enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case ai
    case languageServers
    case usage
    case agents
    case ensemble

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .ai: "AI"
        case .languageServers: "Language Servers"
        case .usage: "Usage"
        case .agents: "Agents"
        case .ensemble: "Ensemble"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintpalette"
        case .ai: "sparkles"
        case .languageServers: "server.rack"
        case .usage: "gauge.medium"
        case .agents: "person.2.badge.gearshape"
        case .ensemble: "circle.hexagongrid"
        }
    }
}

/// Pure layout constants for the Settings window. Every pane shares one
/// width so switching toolbar panes never jumps horizontally.
nonisolated enum SettingsPresentationLayout {
    static let windowWidth: CGFloat = 680
    static let minimumPaneHeight: CGFloat = 460
    static let idealPaneHeight: CGFloat = 560
    static let maximumPaneHeight: CGFloat = 760
    /// Popup buttons size to their content but never narrower than this.
    static let minimumPopupWidth: CGFloat = 140
}
