import SwiftUI

/// Semantic palette roles used by pure presentation resolvers. The enum keeps
/// precedence testable without making `Color` equatable or parsing theme JSON
/// in a view body.
nonisolated enum WorkbenchPaletteRole: Equatable, Sendable {
    case clear
    case editorBackground
    case elevatedBackground
    case tabActiveBackground
    case chipBackground
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

    /// The shelf around a floating tab card is taller than the card itself,
    /// by `RafuMetrics.tabShelfBreathingRoom` on each side, with a floor of
    /// `RafuMetrics.tabShelfHeight` — Larger Text still grows the shelf,
    /// because `tabHeight` is itself a scaled value from `attachedTabHeight`.
    static func tabShelfHeight(forTabHeight tabHeight: CGFloat) -> CGFloat {
        max(tabHeight + RafuMetrics.tabShelfBreathingRoom * 2, RafuMetrics.tabShelfHeight)
    }
}

/// Tabs are detached rounded cards that sit on the tab shelf
/// (`tabBarBackground`: the card tone in Indigo, one step below it in Khadi,
/// never the frame colour). The selected
/// tab is raised: the theme's `tabActiveBackground` fill (a step lighter than
/// the card in Indigo, white in Khadi), a hairline border on all four edges,
/// and its own soft shadow. An inactive tab has no fill at all, only
/// secondary text, so the header row reads as part of the card instead of a
/// strip of chips. Increase Contrast promotes the selected hairline to
/// `borderStrong`; the light theme relies on that hairline and the shadow
/// because its white fill is close to the card tone.
nonisolated struct AttachedWorkbenchTabPresentation: Equatable, Sendable {
    let fill: WorkbenchPaletteRole
    let outline: WorkbenchPaletteRole
    let outlineEdges: Set<WorkbenchBorderEdge>

    static func resolve(isSelected: Bool, contrastIncreased: Bool = false) -> Self {
        guard isSelected else {
            return Self(
                fill: .clear,
                outline: .clear,
                outlineEdges: []
            )
        }
        return Self(
            fill: .tabActiveBackground,
            outline: contrastIncreased ? .borderStrong : .borderSubtle,
            outlineEdges: [.top, .leading, .trailing, .bottom]
        )
    }
}

/// Four corner wedges that visually expose the surrounding surface without
/// changing the decorated content's geometry, hit region, or responder chain.
/// Flat: only for a surface that casts no shadow (an editor group). The deck
/// uses `WorkbenchDeckCornerWedges`, which also repaints its shadow.
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

private nonisolated struct CornerCutoutShape: Shape {
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

/// The single raised editor/utility deck: a card inset from the surrounding
/// frame (`appBackground`). It decorates the existing split hierarchy but
/// never clips or masks its TextKit, SwiftTerm, or splitter descendants.
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
            .background {
                // The shadow is cast by a dedicated rounded shape behind the
                // card's own flat fill, never applied to `content` itself —
                // so it never touches the TextKit/SwiftTerm viewport or
                // forces it offscreen. Reduce Transparency is a no-op here:
                // a shadow is not a material.
                WorkbenchDeckShadowShape(fill: theme.palette.editorBackground, shadow: shadowColor)
            }
            .overlay {
                // The corner wedges repaint what lies behind the card's
                // rounded corners — the frame AND the deck's shadow — above
                // the square-cornered AppKit content. Flat frame-coloured
                // wedges cut the shadow off inside the card's bounding box,
                // which left visible square points at the bottom corners in
                // Khadi (design polish round 4).
                WorkbenchDeckCornerWedges(
                    surrounding: theme.palette.appBackground,
                    fill: theme.palette.editorBackground,
                    shadow: shadowColor
                )
                // The card's edge hairline, in every theme. A light theme's
                // shadow is faint, so this hairline is what separates the
                // card from the frame there; a dark theme reads mostly from
                // its shadow. SwiftUI composites it (and the corner wedges)
                // above the AppKit editor and its scroller.
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
                if theme.isDark {
                    WorkbenchDeckTopHighlight()
                }
            }
    }

    private var shadowColor: Color {
        WorkbenchDeckShadowStyle.color(
            for: .deck,
            isDark: theme.isDark,
            contrastIncreased: colorSchemeContrast == .increased
        )
    }
}

/// The deck's rounded shape and the shadow it casts on the frame. It is drawn
/// twice from this one definition — behind the card, and again inside the
/// corner wedges — so the two copies always match pixel for pixel.
private struct WorkbenchDeckShadowShape: View {
    let fill: Color
    let shadow: Color

    var body: some View {
        RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchDeck, style: .continuous)
            .fill(fill)
            .shadow(
                color: shadow,
                radius: RafuMetrics.deckShadowRadius,
                x: 0,
                y: RafuMetrics.deckShadowY
            )
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The four corner regions between the card's bounding box and its rounded
/// outline, painted as the frame plus the deck's own shadow, so a corner
/// looks exactly like the frame just outside the card. The mask applies only
/// to this decoration layer; the card's content is never clipped or masked
/// (the TextKit/SwiftTerm no-clip rule).
private struct WorkbenchDeckCornerWedges: View {
    let surrounding: Color
    let fill: Color
    let shadow: Color

    var body: some View {
        ZStack {
            Rectangle().fill(surrounding)
            WorkbenchDeckShadowShape(fill: fill, shadow: shadow)
        }
        .mask {
            CornerCutoutShape(radius: RafuMetrics.radiusWorkbenchDeck)
                .fill(style: FillStyle(eoFill: true))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A 1 pt top highlight just inside the dark deck's rim, fading out down the
/// corners, so the card's top edge catches light like a raised surface
/// (design polish round 4). Dark themes only: a white line on a light card
/// would be invisible.
private struct WorkbenchDeckTopHighlight: View {
    /// Tall enough that the continuous corners keep their full shape; the
    /// gradient is clear by half of it.
    private static let height = RafuMetrics.radiusWorkbenchDeck * 4

    var body: some View {
        RoundedRectangle(
            cornerRadius: RafuMetrics.radiusWorkbenchDeck - RafuMetrics.hairline,
            style: .continuous
        )
        .strokeBorder(
            LinearGradient(
                stops: [
                    .init(
                        color: .white.opacity(WorkbenchDeckShadowStyle.topHighlightOpacity),
                        location: 0),
                    .init(color: .white.opacity(0), location: 0.5),
                ],
                startPoint: .top,
                endPoint: .bottom
            ),
            lineWidth: RafuMetrics.hairline
        )
        .padding(RafuMetrics.hairline)
        .frame(height: Self.height)
        .frame(maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Theme-aware shadow opacity for the workbench's only two shadows: the
/// raised deck and the selected tab card. Dark themes read a black shadow
/// stronger, because it must stand out against an already-dark frame; light
/// themes keep it faint, so it stays a soft depth cue rather than a dark halo.
/// Design polish round 4 deepened the deck (dark 0.30 → 0.55, light
/// 0.10 → 0.14) so the card reads clearly raised. The tab's shadow is tighter
/// (`tabShadowRadius`); in a light theme it is the
/// selected tab's main lift, because the white fill is only a step above
/// the shelf (design polish round 3 raised it 0.12 → 0.18). Increase Contrast halves both:
/// that mode's accessibility signal is the already-promoted `borderStrong`
/// hairline, so the shadow stays present but never competes with it as a
/// second, blurrier boundary.
nonisolated enum WorkbenchDeckShadowStyle {
    nonisolated enum Surface: Equatable, Sendable {
        case deck
        case tab
    }

    /// White opacity of the dark deck's 1 pt inner top highlight
    /// (`WorkbenchDeckTopHighlight`). Light themes draw none.
    static let topHighlightOpacity: Double = 0.06

    static func opacity(
        for surface: Surface = .deck, isDark: Bool, contrastIncreased: Bool = false
    ) -> Double {
        let base: Double =
            switch surface {
            case .deck: isDark ? 0.55 : 0.14
            case .tab: isDark ? 0.40 : 0.18
            }
        return contrastIncreased ? base / 2 : base
    }

    static func color(
        for surface: Surface = .deck, isDark: Bool, contrastIncreased: Bool = false
    ) -> Color {
        Color.black.opacity(
            opacity(for: surface, isDark: isDark, contrastIncreased: contrastIncreased))
    }
}

/// Makes the complete tab shape (padding, minimum width and height included)
/// the one click target that selects the tab. The label is plain content,
/// never a `Button`: a button's press tracking owns the mouse-down over the
/// icon and title, so the tab's `.onDrag` could start only from the padding.
/// The close button stays a `Button` and keeps priority in its own area, so
/// "Close" never also selects.
private struct AttachedWorkbenchTabSelectTarget: ViewModifier {
    let select: (() -> Void)?

    func body(content: Content) -> some View {
        if let select {
            content
                .contentShape(.rect)
                .onTapGesture(perform: select)
        } else {
            content
        }
    }
}

/// Accessibility for a tab card's plain label (icon + title, no `Button`):
/// one element that VoiceOver and Full Keyboard Access read as a button,
/// with the selected trait and a default action that selects the tab. The
/// close button stays its own element beside it.
struct WorkbenchTabLabelAccessibility: ViewModifier {
    let label: String
    var value: String = ""
    let isSelected: Bool
    let select: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(.rect)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { select() }
    }
}

extension View {
    /// See `WorkbenchTabLabelAccessibility`.
    func workbenchTabLabel(
        _ label: String, value: String = "", isSelected: Bool, select: @escaping () -> Void
    ) -> some View {
        modifier(
            WorkbenchTabLabelAccessibility(
                label: label, value: value, isSelected: isSelected, select: select))
    }
}

/// Shared detached tab-card chrome for document, terminal, Settings, and
/// Ensemble canvases (window redesign phase 4). Callers keep semantic
/// label/dirty/exit content and may request the bounded document width
/// without changing the selected geometry. Pass `select` so a click
/// anywhere on the tab selects it.
struct AttachedWorkbenchTab<Content: View>: View {
    let isSelected: Bool
    var usesDocumentWidth = false
    var select: (() -> Void)?
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @ScaledMetric(relativeTo: .body) private var scaledHeight = RafuMetrics.tabBarHeight
    /// Hover wash for an unselected (unfilled) tab. Owned here so every tab
    /// kind gets the same feedback without its own background layer.
    @State private var isHovering = false

    init(
        isSelected: Bool,
        usesDocumentWidth: Bool = false,
        select: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.usesDocumentWidth = usesDocumentWidth
        self.select = select
        self.content = content()
    }

    var body: some View {
        let presentation = AttachedWorkbenchTabPresentation.resolve(
            isSelected: isSelected,
            contrastIncreased: colorSchemeContrast == .increased
        )
        content
            // One title style for every tab kind: weight, not only colour,
            // marks the selected tab. An explicit font inside a tab (a pane
            // count, a bell) still wins.
            .font(
                .system(
                    size: RafuMetrics.tabLabelFontSize,
                    weight: isSelected ? .semibold : .medium
                )
            )
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
                RoundedRectangle(cornerRadius: RafuMetrics.radiusWorkbenchTab, style: .continuous)
                    .fill(
                        !isSelected && isHovering
                            ? theme.palette.hover
                            : theme.palette.workbenchColor(for: presentation.fill)
                    )
                    .shadow(
                        color: isSelected
                            ? WorkbenchDeckShadowStyle.color(
                                for: .tab,
                                isDark: theme.isDark,
                                contrastIncreased: colorSchemeContrast == .increased
                            ) : .clear,
                        radius: isSelected ? RafuMetrics.tabShadowRadius : 0,
                        x: 0,
                        y: isSelected ? RafuMetrics.tabShadowY : 0
                    )
            }
            .overlay {
                if presentation.outline != .clear {
                    RoundedRectangle(
                        cornerRadius: RafuMetrics.radiusWorkbenchTab, style: .continuous
                    )
                    .strokeBorder(
                        theme.palette.workbenchColor(for: presentation.outline),
                        lineWidth: RafuMetrics.hairline
                    )
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .modifier(AttachedWorkbenchTabSelectTarget(select: select))
            .onHover { isHovering = $0 }
            .zIndex(isSelected ? 1 : 0)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A terminal, Terminal Group, or Ensemble tab's agent-activity dot, folded
/// from `AgentCardStatus` (`working`/`needsYou`/`failed`/`doneUnread` only —
/// `done`, `inactive`, and `stopped` read as no activity, same as a
/// never-matched session). Kept separate from `AgentCardStatus` itself so
/// this file never imports `RafuCore`'s session-tracking types; the mapping
/// is the only thing a tab needs.
nonisolated enum EditorTabActivityKind: Equatable, Sendable {
    case working
    case needsYou
    case failed
    case doneUnread

    static func from(_ status: AgentCardStatus?) -> Self? {
        switch status {
        case .working: .working
        case .needsYou: .needsYou
        case .failed: .failed
        case .doneUnread: .doneUnread
        case .done, .inactive, .stopped, nil: nil
        }
    }
}

/// What the trailing slot of an editor tab shows. The slot keeps one stable
/// position: "×" on the selected tab and on hover; absent that, a dirty
/// document or an agent-tracked terminal/Terminal Group/Ensemble tab shows a
/// dot there that turns into "×" on hover (the Safari/Xcode pattern). The
/// button stays in the layout and the accessibility tree in every case, so
/// "Close" is always reachable by VoiceOver and Full Keyboard Access.
/// Precedence: hover always wins; failing that, an activity dot (whichever
/// `AgentCardStatus` already resolved to — its own precedence is
/// stopped/failed/needsYou/working/inactive/doneUnread/done) outranks a
/// plain dirty dot, because the two never co-occur on one tab kind in
/// practice but a caller should never need to choose between them.
nonisolated enum EditorTabAccessory: Equatable, Sendable {
    case hidden
    case close
    case dirtyDot
    case activityDot(EditorTabActivityKind)

    static func resolve(
        isSelected: Bool,
        isHovering: Bool,
        isDirty: Bool,
        activity: EditorTabActivityKind? = nil
    ) -> Self {
        if isHovering { return .close }
        if let activity { return .activityDot(activity) }
        if isDirty { return .dirtyDot }
        return isSelected ? .close : .hidden
    }
}

/// Standard close affordance for attached tabs. The glyph and hit region scale
/// independently so larger text never makes the close action unreachable.
/// `presentation` defaults to an always-visible "×" for single-tab canvases.
struct AttachedWorkbenchTabCloseButton: View {
    let accessibilityLabel: String
    let help: String
    var presentation: EditorTabAccessory = .close
    let action: () -> Void

    @Environment(\.rafuTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var scaledTarget: CGFloat = 22

    init(
        accessibilityLabel: String,
        help: String,
        presentation: EditorTabAccessory = .close,
        action: @escaping () -> Void
    ) {
        self.accessibilityLabel = accessibilityLabel
        self.help = help
        self.presentation = presentation
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .opacity(presentation == .close ? 1 : 0)
                Circle()
                    .fill(dotColor ?? .clear)
                    .frame(width: 7, height: 7)
                    .opacity(dotColor == nil ? 0 : 1)
            }
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

    /// `nil` hides the dot entirely (the "×" and the hidden state both pass
    /// through here). Colour is always paired with the tab's own `.help`
    /// and accessibility value text — never the only signal, per the
    /// "never communicate state using colour alone" chrome rule.
    private var dotColor: Color? {
        switch presentation {
        case .dirtyDot: theme.palette.textSecondary
        case .activityDot(.working): theme.palette.accent
        case .activityDot(.needsYou): theme.palette.warning
        case .activityDot(.failed): theme.palette.error
        case .activityDot(.doneUnread): theme.palette.success
        case .close, .hidden: nil
        }
    }
}

/// Text-only content for a tab's delayed hover preview (window redesign
/// phase 4b). Never a thumbnail and never document text — only identity and
/// status words already resolved elsewhere.
nonisolated struct TabHoverPreviewContent: Equatable, Sendable {
    let title: String
    let statusWord: String?
    let subtitle: String
    let elapsedLabel: String?
}

/// Pure builders so the three tab kinds that show a preview cannot drift in
/// what they consider "the subtitle" or "when there is an elapsed label".
nonisolated enum TabHoverPreviewContentBuilder {
    /// A file tab: no status word, the workspace-relative path as subtitle.
    static func file(title: String, workspaceRelativePath: String) -> TabHoverPreviewContent {
        TabHoverPreviewContent(
            title: title, statusWord: nil, subtitle: workspaceRelativePath, elapsedLabel: nil)
    }

    /// A terminal or Terminal Group tab: the agent status word (if any) and
    /// its elapsed label travel together — there is nothing to date without
    /// a matched session, so an ordinary shell's preview never shows a
    /// stale or made-up elapsed time.
    static func terminal(
        title: String,
        shellOrAgentName: String,
        status: AgentCardStatus?,
        elapsedLabel: String?
    ) -> TabHoverPreviewContent {
        TabHoverPreviewContent(
            title: title,
            statusWord: status?.word,
            subtitle: shellOrAgentName,
            elapsedLabel: status == nil ? nil : elapsedLabel
        )
    }

    /// An Ensemble tab: the only status word this board-level preview ever
    /// shows is "Needs approval", and only when some card does.
    static func ensemble(title: String, hasCardNeedingApproval: Bool) -> TabHoverPreviewContent {
        TabHoverPreviewContent(
            title: title,
            statusWord: hasCardNeedingApproval ? "Needs approval" : nil,
            subtitle: "Ensemble",
            elapsedLabel: nil
        )
    }
}

/// The floating card itself: a bold title with the status word trailing on
/// the same line, a secondary subtitle line with the elapsed label trailing.
/// Inert and hidden from accessibility — the tab underneath already
/// announces its own label and value; this is a redundant visual aid that
/// must never take key focus or intercept the pointer.
struct TabHoverPreviewCard: View {
    let content: TabHoverPreviewContent

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RafuMetrics.space2) {
                Text(content.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                if let statusWord = content.statusWord {
                    Spacer(minLength: RafuMetrics.space2)
                    Text(statusWord)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }
            HStack(spacing: RafuMetrics.space2) {
                Text(content.subtitle)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let elapsedLabel = content.elapsedLabel {
                    Spacer(minLength: RafuMetrics.space2)
                    Text(elapsedLabel)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textMuted)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
        .frame(maxWidth: 260, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: RafuMetrics.radiusTransientPopover, style: .continuous)
                .fill(theme.palette.elevatedBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: RafuMetrics.radiusTransientPopover, style: .continuous)
                .strokeBorder(theme.palette.borderSubtle, lineWidth: RafuMetrics.hairline)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
        /// - `hostsTerminal`: the group's selected tab is a terminal or
        ///   Terminal Group. Only then does focus use the gold `focusRing`;
        ///   a document or Canvas group keeps a neutral `borderSubtle` frame.
        /// - `hasSiblings`: more than one editor group is visible. Only then
        ///   does focus carry information for a non-terminal group, and it is
        ///   shown as a subtle `borderStrong` hairline, never gold.
        case editorGroup(isFocused: Bool, hostsTerminal: Bool = false, hasSiblings: Bool = false)
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
        case .editorGroup(let isFocused, let hostsTerminal, let hasSiblings):
            let terminalFocus = isFocused && (hostsTerminal || hasIdentity)
            let siblingFocus = isFocused && hasSiblings && !terminalFocus
            let emphasisWidth: CGFloat =
                if terminalFocus {
                    hasIdentity
                        ? RafuMetrics.terminalBorderWidth
                        : RafuMetrics.focusedTerminalBorderWidth
                } else if siblingFocus {
                    RafuMetrics.terminalBorderWidth
                } else {
                    0
                }
            return TerminalSurfaceBorderResolution(
                neutralStructure: terminalFocus || contrast == .increased
                    ? .borderStrong
                    : .borderSubtle,
                neutralWidth: RafuMetrics.terminalBorderWidth,
                showsIdentityAccent: hasIdentity,
                identityWidth: hasIdentity ? RafuMetrics.focusedTerminalBorderWidth : 0,
                identityInset: hasIdentity ? RafuMetrics.terminalBorderWidth : 0,
                emphasis: (terminalFocus || siblingFocus) ? .editorFocus : .none,
                emphasisRole: terminalFocus
                    ? .focusRing : (siblingFocus ? .borderStrong : .clear),
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
        case .elevatedBackground: elevatedBackground
        case .tabActiveBackground: tabActiveBackground
        case .chipBackground: chipBackground
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
    var hostsTerminal = false
    var hasSiblings = false
    @ViewBuilder let content: Content

    @Environment(\.rafuTheme) private var theme

    init(
        isFocused: Bool,
        terminalIdentityColor: Color? = nil,
        identityMatchesEditorBackground: Bool = false,
        hostsTerminal: Bool = false,
        hasSiblings: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.isFocused = isFocused
        self.terminalIdentityColor = terminalIdentityColor
        self.identityMatchesEditorBackground = identityMatchesEditorBackground
        self.hostsTerminal = hostsTerminal
        self.hasSiblings = hasSiblings
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
                context: .editorGroup(
                    isFocused: isFocused,
                    hostsTerminal: hostsTerminal,
                    hasSiblings: hasSiblings
                ),
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
            // 13 pt glyph in the secondary tone, then the title: the same
            // icon size as every other chrome glyph.
            HStack(spacing: RafuMetrics.space1 + 2) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(theme.palette.textPrimary)
            }
            .accessibilityElement(children: .combine)
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
