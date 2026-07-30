import SwiftUI

/// The seven Settings panes, in navigation order.
///
/// Lifted out of `RafuSettingsView`'s view builder so the set is assertable
/// from a test. The hand-drawn navigation keeps every pane a real `Button`,
/// avoiding AppKit tab chrome that ignores the active Rafu theme tint.
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

    var subtitle: String {
        switch self {
        case .general: "App behavior and common workspace preferences."
        case .appearance: "Choose, import, and create Rafu color themes."
        case .ai: "Configure the provider used for commit-message drafts."
        case .languageServers: "Review language intelligence and workspace trust."
        case .usage: "Choose the usage providers shown by Rafu."
        case .agents: "Manage the external agent CLIs Rafu can orchestrate."
        case .ensemble: "Install the Ensemble skill for your coding tools."
        }
    }
}

/// Pure, canvas-width-only layout policy. Keeping the breakpoint independent
/// of the selected navigation form prevents resize oscillation at 812 points.
nonisolated enum SettingsPresentationLayout {
    static let navigationBreakpoint: CGFloat = 812
    static let regularNavigationWidth: CGFloat = 188
    static let navigationPageGap: CGFloat = 16
    static let pageMaximumWidth: CGFloat = 840
    static let outerPadding: CGFloat = 24
    static let regularCombinedMaximumWidth: CGFloat = 1_092

    static func usesCompactNavigation(forAvailableCanvasWidth width: CGFloat) -> Bool {
        width < navigationBreakpoint
    }
}

/// Rafu's theme-owned Settings navigation, replacing the former AppKit-backed
/// tab bar. Both variants consume the same stable pane metadata and expose
/// real button actions, so selection, keyboard reachability, and VoiceOver
/// semantics do not diverge at the width breakpoint.
struct SettingsPaneNavigation: View {
    enum Variant: Equatable {
        case regular
        case compact
    }

    @Binding var selection: SettingsPane
    let variant: Variant

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            switch variant {
            case .regular:
                VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                    ForEach(SettingsPane.allCases) { pane in
                        SettingsPaneNavigationItem(
                            pane: pane,
                            isSelected: pane == selection,
                            select: { selection = pane }
                        )
                    }
                }
                .padding(RafuMetrics.space2)
                .frame(
                    width: SettingsPresentationLayout.regularNavigationWidth, alignment: .topLeading
                )
            case .compact:
                Menu {
                    ForEach(SettingsPane.allCases) { pane in
                        Button {
                            selection = pane
                        } label: {
                            Label(pane.title, systemImage: pane.systemImage)
                        }
                        .accessibilityLabel(pane.title)
                        .accessibilityAddTraits(pane == selection ? .isSelected : [])
                        .help(pane.title)
                    }
                } label: {
                    Label(selection.title, systemImage: selection.systemImage)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(theme.palette.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .padding(.horizontal, RafuMetrics.space2)
                        .background(
                            theme.palette.accentSoft,
                            in: .rect(cornerRadius: RafuMetrics.radiusDenseSelection)
                        )
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Settings category: \(selection.title)")
                .help("Choose a Settings category")
                .padding(.horizontal, RafuMetrics.space2)
                .padding(.vertical, RafuMetrics.space1)
            }
        }
        .background(theme.palette.tabBarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings categories")
    }
}

private struct SettingsPaneNavigationItem: View {
    let pane: SettingsPane
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Button(action: select) {
            HStack(spacing: RafuMetrics.space2) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 14)
                Text(pane.title)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, RafuMetrics.space2)
            .frame(
                maxWidth: .infinity,
                minHeight: 32,
                alignment: .leading
            )
            .background(background, in: .rect(cornerRadius: RafuMetrics.radiusDenseSelection))
            .contentShape(.rect(cornerRadius: RafuMetrics.radiusDenseSelection))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(pane.title)
    }

    private var foreground: Color {
        if isSelected { return theme.palette.accent }
        return theme.palette.textSecondary
    }

    private var background: Color {
        if isSelected { return theme.palette.accentSoft }
        return .clear
    }
}
