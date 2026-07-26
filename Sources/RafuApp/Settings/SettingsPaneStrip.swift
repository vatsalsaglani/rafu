import SwiftUI

/// The seven Settings panes, in bar order.
///
/// Lifted out of `RafuSettingsView`'s view builder so the set is assertable
/// from a test: the pane bar is hand-drawn now (see `SettingsPaneStrip`), and
/// a hand-drawn bar can silently lose a pane in a way the old tab view's
/// `Tab` literals could not.
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

/// Rafu's own Settings pane bar, replacing SwiftUI's macOS tab-view bar.
///
/// The system bar paints its selected tab with `controlAccentColor` — the
/// *system* accent — which no `.tint` reaches, for the same reason
/// `Picker(.segmented)` resisted tinting and had to become
/// `RafuSegmentedPicker`: both are AppKit segmented-control chrome, not
/// SwiftUI-drawn. Under an Indigo or Khadi theme the selected pane was
/// therefore a blue rectangle in an otherwise themed window.
///
/// The anatomy deliberately matches the macOS Settings bar it replaces —
/// centered row, glyph over label, one selected pill — so it reads native;
/// only the pill's color moves from the system accent to the theme's scarce
/// `accentSoft` wash (the same treatment `RafuIconButtonStyle` already uses
/// for an active nav item). Each pane stays a real `Button`, so Full Keyboard
/// Access reaches all seven and VoiceOver reports the selected one.
struct SettingsPaneStrip: View {
    @Binding var selection: SettingsPane

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space1) {
            ForEach(SettingsPane.allCases) { pane in
                SettingsPaneStripItem(
                    pane: pane,
                    isSelected: pane == selection,
                    select: { selection = pane }
                )
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: .infinity)
        .background(theme.palette.tabBarBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Settings panes")
    }
}

private struct SettingsPaneStripItem: View {
    let pane: SettingsPane
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 3) {
                Image(systemName: pane.systemImage)
                    .font(.system(size: 15, weight: .regular))
                    .frame(height: 17)
                Text(pane.title)
                    .font(.system(size: 10.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(foreground)
            .frame(minWidth: 62)
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(background)
            )
            .contentShape(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        // Pane switching is a navigation action, not a decorative one:
        // AGENTS.md keeps tab/cursor changes immediate, so only the hover
        // wash animates.
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .accessibilityLabel(pane.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .help(pane.title)
    }

    private var foreground: Color {
        if isSelected { return theme.palette.accent }
        if isHovering { return theme.palette.textPrimary }
        return theme.palette.textSecondary
    }

    private var background: Color {
        if isSelected { return theme.palette.accentSoft }
        if isHovering { return theme.palette.hover }
        return .clear
    }
}
