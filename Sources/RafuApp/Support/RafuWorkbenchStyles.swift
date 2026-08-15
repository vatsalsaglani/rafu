import SwiftUI

/// Semantic palette roles used by pure presentation resolvers. The enum keeps
/// precedence testable without making `Color` equatable or parsing theme JSON
/// in a view body.
nonisolated enum WorkbenchPaletteRole: Equatable, Sendable {
    case clear
    case editorBackground
    case tabActiveBackground
    case borderSubtle
    case borderStrong
    case focusRing
    case selection
    case warning
}

nonisolated enum WorkbenchBorderEdge: Equatable, Hashable, Sendable {
    case top
    case leading
    case trailing
    case bottom
}

/// Pure height policy for text-bearing workbench chrome. Heights are floors,
/// never clipping boxes; the selected few that need an upper bound state it
/// explicitly.
nonisolated enum WorkbenchTextHeightPolicy {
    static func attachedTabHeight(for scaledHeight: CGFloat) -> CGFloat {
        min(max(scaledHeight, RafuMetrics.tabBarHeight), 34)
    }

    static func minimumHeight(base: CGFloat, scaledHeight: CGFloat) -> CGFloat {
        max(base, scaledHeight)
    }

    static func attachedTabCloseTarget(for scaledSize: CGFloat) -> CGFloat {
        min(max(scaledSize, 22), 28)
    }
}

nonisolated struct AttachedWorkbenchTabPresentation: Equatable, Sendable {
    let fill: WorkbenchPaletteRole
    let outline: WorkbenchPaletteRole
    let outlineEdges: Set<WorkbenchBorderEdge>
    let masksBottomSeam: Bool

    static func resolve(isSelected: Bool) -> Self {
        guard isSelected else {
            return Self(
                fill: .clear,
                outline: .clear,
                outlineEdges: [],
                masksBottomSeam: false
            )
        }
        return Self(
            fill: .tabActiveBackground,
            outline: .borderStrong,
            outlineEdges: [.top, .leading, .trailing],
            masksBottomSeam: true
        )
    }
}

/// Four corner wedges that visually expose the surrounding surface without
/// changing the decorated content's geometry, hit region, or responder chain.
struct CornerCutoutOverlay: View {
    let radius: CGFloat
    let surrounding: Color

    var body: some View {
        CornerCutoutShape(radius: radius)
            .fill(surrounding, style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

private struct CornerCutoutShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: radius, height: radius),
            style: .continuous
        )
        return path
    }
}

/// The single recessed editor/utility deck. It decorates the existing split
/// hierarchy but never clips or masks its TextKit, SwiftTerm, or splitter
/// descendants.
struct WorkbenchDeckSurface<Content: View>: View {
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .background(theme.palette.editorBackground)
            .overlay {
                CornerCutoutOverlay(
                    radius: RafuMetrics.radiusWorkbenchDeck,
                    surrounding: theme.palette.appBackground
                )
                RoundedRectangle(
                    cornerRadius: RafuMetrics.radiusWorkbenchDeck,
                    style: .continuous
                )
                .strokeBorder(
                    colorSchemeContrast == .increased
                        ? theme.palette.borderStrong
                        : theme.palette.borderSubtle,
                    lineWidth: RafuMetrics.hairline
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
    }
}

private struct AttachedTabFillShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// An open-bottom outline: top and both sides are structural; the owning tab
/// shelf keeps the full-width bottom seam.
private struct AttachedTabOutlineShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

/// Shared attached-cap chrome for document, terminal, Settings, and Ensemble
/// canvases. Callers keep semantic label/dirty/exit content and may request
/// the bounded document width without changing the selected geometry.
struct AttachedWorkbenchTab<Content: View>: View {
    let isSelected: Bool
    var usesDocumentWidth = false
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaledHeight = RafuMetrics.tabBarHeight

    init(
        isSelected: Bool,
        usesDocumentWidth: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.usesDocumentWidth = usesDocumentWidth
        self.content = content()
    }

    var body: some View {
        let presentation = AttachedWorkbenchTabPresentation.resolve(isSelected: isSelected)
        content
            .foregroundStyle(
                isSelected ? theme.palette.textPrimary : theme.palette.textSecondary
            )
            .padding(.horizontal, RafuMetrics.space2)
            .frame(
                minWidth: usesDocumentWidth ? 96 : nil,
                maxWidth: usesDocumentWidth ? 220 : nil,
                minHeight: WorkbenchTextHeightPolicy.attachedTabHeight(for: scaledHeight)
            )
            .background {
                if presentation.fill == .tabActiveBackground {
                    AttachedTabFillShape(radius: RafuMetrics.radiusAttachedTab)
                        .fill(theme.palette.tabActiveBackground)
                }
            }
            .overlay {
                if presentation.outline == .borderStrong {
                    AttachedTabOutlineShape(radius: RafuMetrics.radiusAttachedTab)
                        .stroke(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(alignment: .bottom) {
                if presentation.masksBottomSeam {
                    Rectangle()
                        .fill(theme.palette.tabActiveBackground)
                        .frame(height: RafuMetrics.hairline)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .zIndex(isSelected ? 1 : 0)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Standard close affordance for attached tabs. The glyph and hit region scale
/// independently so larger text never makes the close action unreachable.
struct AttachedWorkbenchTabCloseButton: View {
    let accessibilityLabel: String
    let help: String
    let action: () -> Void

    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaledTarget: CGFloat = 22

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .frame(
                    width: WorkbenchTextHeightPolicy.attachedTabCloseTarget(
                        for: scaledTarget
                    ),
                    height: WorkbenchTextHeightPolicy.attachedTabCloseTarget(
                        for: scaledTarget
                    )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .help(help)
    }
}

nonisolated enum TerminalSurfaceIdentity: Equatable, Sendable {
    case none
    case assigned(matchesEditorBackground: Bool)
}

nonisolated enum TerminalSurfaceContrast: Equatable, Sendable {
    case normal
    case increased
}

nonisolated struct TerminalSurfaceBorderResolution: Equatable, Sendable {
    nonisolated enum Layer: Equatable, Sendable {
        case neutralStructure
        case emphasis
        case identity
    }

    nonisolated enum Emphasis: Equatable, Sendable {
        case none
        case editorFocus
        case managerCurrent
        case managerAttention
    }

    nonisolated enum RowFill: Equatable, Sendable {
        case none
        case current
    }

    let neutralStructure: WorkbenchPaletteRole
    let neutralWidth: CGFloat
    let showsIdentityAccent: Bool
    let identityWidth: CGFloat
    let identityInset: CGFloat
    let emphasis: Emphasis
    let emphasisRole: WorkbenchPaletteRole
    let emphasisWidth: CGFloat
    let emphasisInset: CGFloat
    let drawOrder: [Layer]
    let rowFill: RowFill

    var identityAndEmphasisDoNotOverlap: Bool {
        guard showsIdentityAccent, emphasis != .none else { return true }
        return identityInset >= emphasisInset + emphasisWidth
    }
}

/// Context-aware terminal perimeter contract shared by editor groups and
/// manager rows. Status is deliberately not an input: running/exited state
/// remains a separate textual/icon signal owned by the terminal presentation.
nonisolated struct TerminalSurfaceBorderStyle {
    nonisolated enum Context: Equatable, Sendable {
        case editorGroup(isFocused: Bool)
        case managerRow(isCurrent: Bool, needsAttention: Bool)
    }

    let context: Context
    let identity: TerminalSurfaceIdentity

    func resolution(contrast: TerminalSurfaceContrast) -> TerminalSurfaceBorderResolution {
        Self.resolve(context: context, identity: identity, contrast: contrast)
    }

    static func resolve(
        context: Context,
        identity: TerminalSurfaceIdentity,
        contrast: TerminalSurfaceContrast
    ) -> TerminalSurfaceBorderResolution {
        let hasIdentity = identity != .none
        switch context {
        case .editorGroup(let isFocused):
            let emphasisWidth: CGFloat =
                if isFocused {
                    hasIdentity
                        ? RafuMetrics.terminalBorderWidth
                        : RafuMetrics.focusedTerminalBorderWidth
                } else {
                    0
                }
            return TerminalSurfaceBorderResolution(
                neutralStructure: isFocused || contrast == .increased
                    ? .borderStrong
                    : .borderSubtle,
                neutralWidth: RafuMetrics.terminalBorderWidth,
                showsIdentityAccent: hasIdentity,
                identityWidth: hasIdentity ? RafuMetrics.focusedTerminalBorderWidth : 0,
                identityInset: hasIdentity ? RafuMetrics.terminalBorderWidth : 0,
                emphasis: isFocused ? .editorFocus : .none,
                emphasisRole: isFocused ? .focusRing : .clear,
                emphasisWidth: emphasisWidth,
                emphasisInset: 0,
                drawOrder: hasIdentity
                    ? [.neutralStructure, .emphasis, .identity]
                    : [.neutralStructure, .emphasis],
                rowFill: .none
            )
        case .managerRow(let isCurrent, let needsAttention):
            let emphasis: TerminalSurfaceBorderResolution.Emphasis =
                needsAttention ? .managerAttention : (isCurrent ? .managerCurrent : .none)
            let emphasisWidth =
                emphasis == .none ? 0 : RafuMetrics.terminalBorderWidth
            return TerminalSurfaceBorderResolution(
                neutralStructure: isCurrent || needsAttention || contrast == .increased
                    ? .borderStrong
                    : .borderSubtle,
                neutralWidth: RafuMetrics.terminalBorderWidth,
                showsIdentityAccent: hasIdentity,
                identityWidth: hasIdentity ? RafuMetrics.focusedTerminalBorderWidth : 0,
                identityInset: hasIdentity ? RafuMetrics.terminalBorderWidth : 0,
                emphasis: emphasis,
                emphasisRole: needsAttention ? .warning : (isCurrent ? .focusRing : .clear),
                emphasisWidth: emphasisWidth,
                emphasisInset: 0,
                drawOrder: hasIdentity
                    ? [.neutralStructure, .emphasis, .identity]
                    : [.neutralStructure, .emphasis],
                rowFill: isCurrent ? .current : .none
            )
        }
    }
}

extension RafuThemePalette {
    fileprivate func workbenchColor(for role: WorkbenchPaletteRole) -> Color {
        switch role {
        case .clear: .clear
        case .editorBackground: editorBackground
        case .tabActiveBackground: tabActiveBackground
        case .borderSubtle: borderSubtle
        case .borderStrong: borderStrong
        case .focusRing: focusRing
        case .selection: selection
        case .warning: warning
        }
    }
}

private struct TerminalSurfaceBorderModifier: ViewModifier {
    let style: TerminalSurfaceBorderStyle
    let identityColor: Color?
    let radius: CGFloat

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let surfaceContrast: TerminalSurfaceContrast =
            colorSchemeContrast == .increased ? .increased : .normal
        let resolution = style.resolution(contrast: surfaceContrast)
        content
            .background {
                if resolution.rowFill == .current {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(theme.palette.selection)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        theme.palette.workbenchColor(for: resolution.neutralStructure),
                        lineWidth: resolution.neutralWidth
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                if resolution.emphasis != .none {
                    RoundedRectangle(
                        cornerRadius: max(0, radius - resolution.emphasisInset),
                        style: .continuous
                    )
                    .strokeBorder(
                        theme.palette.workbenchColor(for: resolution.emphasisRole),
                        lineWidth: resolution.emphasisWidth
                    )
                    .padding(resolution.emphasisInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                if resolution.showsIdentityAccent, let identityColor {
                    RoundedRectangle(
                        cornerRadius: max(0, radius - resolution.identityInset),
                        style: .continuous
                    )
                    .strokeBorder(identityColor, lineWidth: resolution.identityWidth)
                    .padding(resolution.identityInset)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func rafuTerminalSurfaceBorder(
        context: TerminalSurfaceBorderStyle.Context,
        identityColor: Color? = nil,
        identityMatchesEditorBackground: Bool = false,
        radius: CGFloat
    ) -> some View {
        modifier(
            TerminalSurfaceBorderModifier(
                style: TerminalSurfaceBorderStyle(
                    context: context,
                    identity: identityColor == nil
                        ? .none
                        : .assigned(matchesEditorBackground: identityMatchesEditorBackground)
                ),
                identityColor: identityColor,
                radius: radius
            )
        )
    }
}

/// One editor-group frame containing its attached tab and content. Opaque
/// children are visually rounded with cutout overlays rather than clipped.
struct EditorGroupSurface<Content: View>: View {
    let isFocused: Bool
    let terminalIdentityColor: Color?
    var identityMatchesEditorBackground = false
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme

    init(
        isFocused: Bool,
        terminalIdentityColor: Color? = nil,
        identityMatchesEditorBackground: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.isFocused = isFocused
        self.terminalIdentityColor = terminalIdentityColor
        self.identityMatchesEditorBackground = identityMatchesEditorBackground
        self.content = content()
    }

    var body: some View {
        content
            .background(theme.palette.editorBackground)
            .overlay {
                CornerCutoutOverlay(
                    radius: RafuMetrics.radiusEditorGroup,
                    surrounding: theme.palette.appBackground
                )
            }
            .rafuTerminalSurfaceBorder(
                context: .editorGroup(isFocused: isFocused),
                identityColor: terminalIdentityColor,
                identityMatchesEditorBackground: identityMatchesEditorBackground,
                radius: RafuMetrics.radiusEditorGroup
            )
    }
}

/// Shared one-row panel header. The supplied context and action builders are
/// stored as values so the header remains a normal SwiftUI diffing boundary.
struct RafuUtilityPanelHeader<Context: View, Actions: View>: View {
    let icon: String
    let title: String
    let closeAccessibilityLabel: String
    let onClose: () -> Void
    @ViewBuilder let context: Context
    @ViewBuilder let actions: Actions

    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaledMinimumHeight =
        RafuMetrics.sectionHeaderHeight

    init(
        icon: String,
        title: String,
        closeAccessibilityLabel: String,
        onClose: @escaping () -> Void,
        @ViewBuilder context: () -> Context,
        @ViewBuilder actions: () -> Actions
    ) {
        self.icon = icon
        self.title = title
        self.closeAccessibilityLabel = closeAccessibilityLabel
        self.onClose = onClose
        self.context = context()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            context
            Spacer(minLength: RafuMetrics.space2)
            actions
            Button(action: onClose) {
                Label("Close", systemImage: "xmark")
            }
            .buttonStyle(RafuIconButtonStyle(size: 24))
            .accessibilityLabel(closeAccessibilityLabel)
            .help(closeAccessibilityLabel)
        }
        .padding(.horizontal, RafuMetrics.utilityBodyInset)
        .frame(
            minHeight: WorkbenchTextHeightPolicy.minimumHeight(
                base: RafuMetrics.sectionHeaderHeight,
                scaledHeight: scaledMinimumHeight
            )
        )
        .background(theme.palette.elevatedBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.borderSubtle)
                .frame(height: RafuMetrics.hairline)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

extension RafuUtilityPanelHeader where Context == EmptyView {
    init(
        icon: String,
        title: String,
        closeAccessibilityLabel: String,
        onClose: @escaping () -> Void,
        @ViewBuilder actions: () -> Actions
    ) {
        self.init(
            icon: icon,
            title: title,
            closeAccessibilityLabel: closeAccessibilityLabel,
            onClose: onClose,
            context: { EmptyView() },
            actions: actions
        )
    }
}

/// Shared lower-emphasis panel state. It expands to the remaining panel body,
/// so the concrete panel's primary header stays pinned at the top.
struct RafuPanelEmptyState<Action: View>: View {
    let icon: String
    let title: String
    let message: String
    @ViewBuilder let action: Action

    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .title3) private var iconSize: CGFloat = 30

    init(
        icon: String,
        title: String,
        message: String,
        @ViewBuilder action: () -> Action
    ) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: RafuMetrics.space3) {
            Image(systemName: icon)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(theme.palette.textSecondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .multilineTextAlignment(.center)
            Text(message)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(RafuMetrics.utilityBodyInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
    }
}

extension RafuPanelEmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String) {
        self.init(icon: icon, title: title, message: message) {
            EmptyView()
        }
    }
}

/// Minimum-height row for custom settings sections. Multi-line content grows
/// naturally because the height is a floor rather than an exact frame.
struct RafuSettingsRow<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(
                maxWidth: .infinity,
                minHeight: RafuMetrics.settingsRowMinHeight,
                alignment: .leading
            )
            .accessibilityElement(children: .contain)
    }
}

/// A theme-owned settings group that restores the heading and containment
/// semantics supplied by native `Section` while leaving every control native.
struct RafuSettingsSection<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    @Environment(\.rafuTheme) private var theme

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            header
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            content
            footer
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(RafuMetrics.settingsSectionInset)
        .background {
            RoundedRectangle(
                cornerRadius: RafuMetrics.radiusDenseCard,
                style: .continuous
            )
            .fill(theme.palette.cardBackground)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: RafuMetrics.radiusDenseCard,
                style: .continuous
            )
            .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .contain)
    }
}

extension RafuSettingsSection where Footer == EmptyView {
    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.init(header: header, content: content, footer: { EmptyView() })
    }
}
