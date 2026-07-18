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
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                        .fill(background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                        .strokeBorder(
                            theme.palette.accent.opacity(isActive ? 0.5 : 0),
                            lineWidth: RafuMetrics.hairline
                        )
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                )
                .onHover { isHovering = $0 }
                .animation(.easeOut(duration: 0.12), value: isHovering)
                .animation(.easeOut(duration: 0.12), value: isActive)
                .opacity(isEnabled ? 1 : 0.35)
        }

        private var foreground: Color {
            if isActive { return theme.palette.accent }
            if isHovering { return theme.palette.textPrimary }
            return theme.palette.textSecondary
        }

        private var background: Color {
            // Selected nav items read as a scarce accent wash + hairline
            // outline (references); pressed and hover stay neutral washes.
            if isActive { return theme.palette.accentSoft }
            if configuration.isPressed { return theme.palette.selection }
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

/// Capsule chip for inline metadata: counts, languages, statuses, and
/// keyboard-shortcut hints (diff +N/-N, blame line counts, palette shortcut
/// hints, code-block languages). Matches the anatomy already hand-rolled by
/// `GitInspectorView`'s worktree chips.
struct RafuChip: View {
    private let label: Text
    var foreground: Color? = nil
    var monospacedDigit: Bool = false

    @Environment(\.rafuTheme) private var theme

    init(text: String, foreground: Color? = nil, monospacedDigit: Bool = false) {
        self.label = Text(text)
        self.foreground = foreground
        self.monospacedDigit = monospacedDigit
    }

    /// Wraps a pre-built `Text`, e.g. `Text(date, style: .relative)`, so a
    /// chip can host SwiftUI's self-updating relative-date rendering
    /// instead of a one-shot formatted string.
    init(_ label: Text, foreground: Color? = nil, monospacedDigit: Bool = false) {
        self.label = label
        self.foreground = foreground
        self.monospacedDigit = monospacedDigit
    }

    var body: some View {
        label
            .font(.system(size: 10.5, weight: .medium))
            .modifier(MonospacedDigitIfNeeded(enabled: monospacedDigit))
            .foregroundStyle(foreground ?? theme.palette.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.palette.chipBackground))
    }

    private struct MonospacedDigitIfNeeded: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if enabled {
                content.monospacedDigit()
            } else {
                content
            }
        }
    }
}

/// Card header row anatomy shared by diff/blame headers, code-block cards,
/// and other embedded-content chrome: a leading label/chip slot, a trailing
/// actions slot, `cardBackground` fill, and a bottom hairline.
struct RafuCardHeaderRow<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    @Environment(\.rafuTheme) private var theme

    init(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            leading
            Spacer(minLength: RafuMetrics.space2)
            trailing
        }
        .padding(.horizontal, RafuMetrics.space3)
        .frame(height: RafuMetrics.sectionHeaderHeight)
        .background(theme.palette.cardBackground)
        .overlay(alignment: .bottom) {
            Divider().overlay(theme.palette.borderSubtle)
        }
    }
}

extension RafuCardHeaderRow where Trailing == EmptyView {
    init(@ViewBuilder leading: () -> Leading) {
        self.leading = leading()
        self.trailing = EmptyView()
    }
}

/// Filled-field chrome for single/multi-line text inputs: `fieldBackground`
/// fill at `RafuMetrics.radiusField`, a `borderSubtle` hairline at rest, and
/// a `focusRing` hairline when focused. `.roundedBorder`'s system chrome
/// draws its own focus ring for free; a plain field loses that, so callers
/// MUST thread their `@FocusState` through `isFocused` to keep Full Keyboard
/// Access legible.
struct RafuFieldModifier: ViewModifier {
    var isFocused: Bool = false

    @Environment(\.rafuTheme) private var theme

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, RafuMetrics.space1)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                    .fill(theme.palette.fieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                    .strokeBorder(
                        isFocused ? theme.palette.focusRing : theme.palette.borderSubtle,
                        lineWidth: RafuMetrics.hairline
                    )
            )
    }
}

extension View {
    /// Applies the flat filled-field chrome (see `RafuFieldModifier`).
    /// Pass the field's `@FocusState` binding value to preserve the
    /// system's focus-ring affordance that `.roundedBorder` provided.
    func rafuField(isFocused: Bool = false) -> some View {
        modifier(RafuFieldModifier(isFocused: isFocused))
    }
}

/// Shared sheet header anatomy: a leading glyph plus a title/subtitle
/// stack. Used by every custom sheet restyled under ADR 0012 so their
/// headers read consistently.
struct RafuSheetHeader: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
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
