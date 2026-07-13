import SwiftUI

/// Icon button used across chrome (sidebar headers, panels, tab bars).
/// Quiet at rest, visible wash on hover, accent when active.
struct RafuIconButtonStyle: ButtonStyle {
    var isActive: Bool = false
    var size: CGFloat = 26
    var iconSize: CGFloat = 12

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(
            configuration: configuration,
            isActive: isActive,
            size: size,
            iconSize: iconSize
        )
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let isActive: Bool
        let size: CGFloat
        let iconSize: CGFloat
        @Environment(\.rafuTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .labelStyle(.iconOnly)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(background)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .opacity(isEnabled ? 1 : 0.35)
        }

        private var foreground: Color {
            if isActive { return theme.palette.accent }
            if isHovering { return theme.palette.textPrimary }
            return theme.palette.textSecondary
        }

        private var background: Color {
            if configuration.isPressed { return theme.palette.selection }
            if isActive { return theme.palette.selection }
            if isHovering { return theme.palette.hover }
            return .clear
        }
    }
}

/// Filled accent button (Commit, Save, primary sheet actions).
struct RafuProminentButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, compact: compact)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.rafuTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                .foregroundStyle(theme.palette.onAccent)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .opacity(isEnabled ? 1 : 0.4)
        }

        private var fill: Color {
            if configuration.isPressed { return theme.palette.accent.opacity(0.85) }
            if isHovering { return theme.palette.accentHover }
            return theme.palette.accent
        }
    }
}

/// Quiet bordered button (Stage All, Test Connection, secondary actions).
struct RafuSecondaryButtonStyle: ButtonStyle {
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration, compact: compact)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        let compact: Bool
        @Environment(\.rafuTheme) private var theme
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 11.5 : 12.5, weight: .medium))
                .foregroundStyle(theme.palette.textPrimary)
                .padding(.horizontal, compact ? 10 : 14)
                .padding(.vertical, compact ? 4 : 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(fill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isHovering
                                ? theme.palette.borderStrong
                                : theme.palette.borderSubtle
                        )
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .opacity(isEnabled ? 1 : 0.4)
        }

        private var fill: Color {
            if configuration.isPressed { return theme.palette.selection }
            if isHovering { return theme.palette.hover }
            return theme.palette.elevatedBackground
        }
    }
}

/// Theme-tinted segmented control replacing the system blue segmented picker.
struct RafuSegmentedPicker<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let title: (Item) -> String

    @Environment(\.rafuTheme) private var theme
    @Namespace private var segmentNamespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                segment(for: item)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.palette.appBackground.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle)
        )
    }

    private func segment(for item: Item) -> some View {
        let isSelected = item == selection
        return Button {
            withAnimation(.spring(duration: 0.25)) { selection = item }
        } label: {
            Text(title(item))
                .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(
                    isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 3.5)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                            .fill(theme.palette.elevatedBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                    .strokeBorder(theme.palette.borderStrong.opacity(0.6))
                            )
                            .matchedGeometryEffect(id: "segment", in: segmentNamespace)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 5.5, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Hover-highlighting row container for custom list-like stacks.
struct RafuHoverRow<Content: View>: View {
    var isSelected: Bool = false
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme
    @State private var isHovering = false

    var body: some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.1), value: isHovering)
    }

    private var background: Color {
        if isSelected { return theme.palette.selection }
        if isHovering { return theme.palette.hover }
        return .clear
    }
}
