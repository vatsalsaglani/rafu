import SwiftUI

// The companion's shared chrome, after Cider's notch: one set of tokens, one
// outline, one gradient border, and one agent card for the notch panel, the
// attention drop-down (`NotchHUDView`), and the menu bar card. The island
// capsule keeps its own all-round shape (ADR 0037).

// MARK: - Tokens

/// Spacing and size tokens for the companion surfaces. Values follow
/// Cider's `CiderPillPicker`, `NotchHUDView`, and `AgentsView`; the tab
/// padding is larger than Cider's because a Rafu tab has an icon, a title,
/// and a count.
nonisolated enum CompanionChromeMetrics {
    /// Inner padding of the tab track round its options.
    static let tabTrackPadding: CGFloat = 3
    /// Space between two tab options.
    static let tabOptionSpacing: CGFloat = 2
    /// Option height on the notch panel (compact).
    static let tabOptionHeightCompact: CGFloat = 28
    /// Option height on the menu bar card, which has more room.
    static let tabOptionHeightRegular: CGFloat = 32
    /// Horizontal padding inside one option.
    static let tabOptionHorizontalPadding: CGFloat = 10
    /// Track fill, white over the black surface.
    static let tabTrackOpacity: Double = 0.065
    /// Selected option fill, white over the black surface.
    static let tabSelectedOpacity: Double = 0.14
    /// Pressed option tint, accent.
    static let tabPressedAccentOpacity: Double = 0.1
    /// Above this many tabs the options take their own widths, so a long
    /// title ("Now Playing") is not cut.
    static let equalWidthTabLimit = 3
    /// The tab row's outer padding.
    static let tabBarHorizontalPadding: CGFloat = 16
    static let tabBarTopPadding: CGFloat = 10
    static let tabBarBottomPadding: CGFloat = 8
    /// The trailing pin or close button, and its gap from the track.
    static let tabAccessorySize: CGFloat = 28
    static let tabAccessorySpacing: CGFloat = 12

    /// Horizontal padding of every section's content.
    static let contentHorizontalPadding: CGFloat = 16
    /// Vertical space between the blocks of one section.
    static let sectionSpacing: CGFloat = 10

    /// Agent card anatomy (Cider `AgentsView`, compact).
    static let cardPadding: CGFloat = 10
    static let cardCornerRadius: CGFloat = 14
    static let cardFillOpacity: Double = 0.04
    static let cardRowSpacing: CGFloat = 5

    static func tabOptionHeight(for host: CompanionHost) -> CGFloat {
        host == .menuBar ? tabOptionHeightRegular : tabOptionHeightCompact
    }

    /// Equal widths for a short tab row; own widths for a long one.
    static func usesEqualTabWidths(tabCount: Int) -> Bool {
        tabCount <= equalWidthTabLimit
    }
}

// MARK: - Outline

/// The largest shoulder and bottom radius an outline may use. The real
/// values also depend on the height (`metrics(height:)`).
nonisolated struct CompanionOutlineLimits: Equatable, Sendable {
    var shoulder: CGFloat
    var radius: CGFloat

    /// The open panel and the attention drop-down under a notch: Cider's
    /// `NotchOutline` (concave shoulders 12, bottom radius 22).
    static let open = CompanionOutlineLimits(shoulder: 12, radius: 22)
    /// The resting strip: no shoulders, the panel radius.
    static let closed = CompanionOutlineLimits(shoulder: 0, radius: RafuMetrics.radiusPanel)

    /// Cider's clamps: the shoulder is at most a third of the height, the
    /// bottom radius at most half.
    func metrics(height: CGFloat) -> CompanionOutlineMetrics {
        let h = max(0, height)
        return CompanionOutlineMetrics(shoulder: min(shoulder, h / 3), radius: min(radius, h / 2))
    }
}

nonisolated struct CompanionOutlineMetrics: Equatable, Sendable {
    let shoulder: CGFloat
    let radius: CGFloat
}

/// A surface that hangs from the top edge of the screen: the top edge is
/// flush, concave shoulders curve out to it at both top corners, and the
/// bottom corners are round. With no shoulder it is a bottom-rounded
/// rectangle. The same path fills, clips, strokes, and hit-tests the panel
/// (`NotchHUDPassthroughHostingView.hitOutline`).
nonisolated struct CompanionOutline: Shape {
    var limits: CompanionOutlineLimits
    /// `true` for the border: the path leaves out the top edge, which sits
    /// against the screen edge or the housing.
    var openTop = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(limits.shoulder, limits.radius) }
        set { limits = CompanionOutlineLimits(shoulder: newValue.first, radius: newValue.second) }
    }

    func path(in rect: CGRect) -> Path {
        Path(Self.cgPath(in: rect, limits: limits, openTop: openTop))
    }

    /// The outline in a top-left-origin (y down) space, as SwiftUI draws.
    static func cgPath(in rect: CGRect, limits: CompanionOutlineLimits, openTop: Bool = false)
        -> CGPath
    {
        let metrics = limits.metrics(height: rect.height)
        let s = metrics.shoulder
        let r = metrics.radius
        let w = rect.width
        let h = rect.height
        let path = CGMutablePath()
        // Clockwise from the top-left corner, as Cider's `NotchOutline`.
        path.move(to: .zero)
        if openTop {
            path.move(to: CGPoint(x: w, y: 0))
        } else {
            path.addLine(to: CGPoint(x: w, y: 0))
        }
        path.addQuadCurve(to: CGPoint(x: w - s, y: s), control: CGPoint(x: w - s, y: 0))
        path.addLine(to: CGPoint(x: w - s, y: h - r))
        path.addQuadCurve(to: CGPoint(x: w - s - r, y: h), control: CGPoint(x: w - s, y: h))
        path.addLine(to: CGPoint(x: s + r, y: h))
        path.addQuadCurve(to: CGPoint(x: s, y: h - r), control: CGPoint(x: s, y: h))
        path.addLine(to: CGPoint(x: s, y: s))
        path.addQuadCurve(to: .zero, control: CGPoint(x: s, y: 0))
        if !openTop { path.closeSubpath() }
        var transform = CGAffineTransform(translationX: rect.minX, y: rect.minY)
        return path.copy(using: &transform) ?? path
    }

    /// Whether `point` (top-left origin, y down) is inside the outline of a
    /// surface of `size`.
    static func contains(_ point: CGPoint, size: CGSize, limits: CompanionOutlineLimits) -> Bool {
        cgPath(in: CGRect(origin: .zero, size: size), limits: limits).contains(point)
    }
}

// MARK: - Gradient border

/// How the companion's gradient border draws, or `nil` for no border.
nonisolated struct CompanionGlowState: Equatable, Sendable {
    enum Fill: Equatable, Sendable {
        /// Cider's orange-to-accent gradient with faded ends.
        case gradient
        /// Reduce Transparency: the same hues with no faded stops.
        case opaqueGradient
        /// Increase Contrast: one solid strong border colour.
        case solid
    }

    enum Motion: Equatable, Sendable {
        case still
        /// The short sweep after an attention event.
        case attentionSweep
        /// The slow sweep while the surface is open and an agent works.
        case workingSweep
    }

    let fill: Fill
    let motion: Motion
    let lineWidth: CGFloat

    /// Seconds one turn of the gradient takes.
    var period: Double? {
        switch motion {
        case .still: nil
        case .attentionSweep: CompanionGlowPolicy.attentionSweepPeriod
        case .workingSweep: CompanionGlowPolicy.workingSweepPeriod
        }
    }
}

/// The pure decision for the gradient border. The border shows only while
/// its surface is open. It moves only for `attentionSweepDuration` after an
/// attention event, or slowly while an agent works; otherwise it is still.
/// Reduce Motion, a hidden window, and a locked screen keep it still;
/// Increase Contrast makes it one solid line; Reduce Transparency removes
/// the faded stops.
nonisolated enum CompanionGlowPolicy {
    static let attentionSweepDuration: TimeInterval = 2.4
    /// One full turn during the attention sweep.
    static let attentionSweepPeriod: Double = 1.2
    /// One full turn while an agent works.
    static let workingSweepPeriod: Double = 8
    /// The timeline's frame cap while the border moves.
    static let frameInterval: Double = 1.0 / 30
    static let lineWidth: CGFloat = 1
    /// Cider's peek width: during the attention sweep.
    static let attentionLineWidth: CGFloat = 2

    static func resolve(
        visible: Bool,
        motionAllowed: Bool,
        reduceMotion: Bool,
        increaseContrast: Bool,
        reduceTransparency: Bool,
        anyWorking: Bool,
        sweepUntil: Date?,
        now: Date
    ) -> CompanionGlowState? {
        guard visible else { return nil }
        let sweeping = sweepUntil.map { now < $0 } ?? false
        let lineWidth = sweeping ? attentionLineWidth : self.lineWidth
        if increaseContrast {
            return CompanionGlowState(fill: .solid, motion: .still, lineWidth: lineWidth)
        }
        let fill: CompanionGlowState.Fill = reduceTransparency ? .opaqueGradient : .gradient
        let motion: CompanionGlowState.Motion
        if !motionAllowed || reduceMotion {
            motion = .still
        } else if sweeping {
            motion = .attentionSweep
        } else if anyWorking {
            motion = .workingSweep
        } else {
            motion = .still
        }
        return CompanionGlowState(fill: fill, motion: motion, lineWidth: lineWidth)
    }

    /// A new attention event: the count went up.
    static func startsSweep(oldAttention: Int, newAttention: Int) -> Bool {
        newAttention > oldAttention
    }

    /// The gradient's angle in degrees at `date` for a moving border; 0 when
    /// still. Pure, so the timeline closure does no layout work.
    static func angle(at date: Date, period: Double?) -> Double {
        guard let period, period > 0 else { return 0 }
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period)
        return phase / period * 360
    }
}

/// The hue of the gradient border. The companion surfaces use `.standard`;
/// the approval peek is amber while it waits, then green on allow and red on
/// deny. The peek also shows a word for each result, so the state never
/// rests on colour alone.
nonisolated enum CompanionGlowTone: Equatable, Sendable {
    case standard
    case waiting
    case allowed
    case denied
}

/// The gradient's colours from theme tokens: Cider's orange becomes the
/// theme's warning hue and its pink becomes the accent.
struct CompanionGlowGradient {
    static func colors(
        for fill: CompanionGlowState.Fill, palette: RafuThemePalette,
        tone: CompanionGlowTone = .standard
    ) -> [Color] {
        // Increase Contrast: one solid strong line, whatever the tone.
        if fill == .solid { return [palette.borderStrong] }
        let single: Color
        switch tone {
        case .standard:
            return fill == .gradient
                ? [
                    palette.warning.opacity(0.15), palette.warning, palette.accent.opacity(0.65),
                    palette.warning.opacity(0.15),
                ]
                : [palette.warning, palette.accent, palette.warning]
        case .waiting: single = palette.warning
        case .allowed: single = palette.success
        case .denied: single = palette.error
        }
        // One hue with faded ends; Reduce Transparency drops the faded stops.
        return fill == .gradient
            ? [single.opacity(0.15), single, single.opacity(0.65), single.opacity(0.15)]
            : [single, single]
    }
}

extension View {
    /// Draws the companion's gradient border along `stroke`, inside `clip`.
    /// `attention` is a count that goes up on each new attention event;
    /// `sweepKey` starts a sweep whenever it changes to a new non-nil value
    /// (the drop-down's event). `tone` picks the hue (`CompanionGlowTone`).
    /// Apply under `rafuMotionScope()`.
    func companionGlowBorder<Stroke: Shape, Clip: Shape>(
        stroke: Stroke, clip: Clip, visible: Bool, anyWorking: Bool, attention: Int = 0,
        sweepKey: UUID? = nil, tone: CompanionGlowTone = .standard
    ) -> some View {
        modifier(
            CompanionGlowBorder(
                stroke: stroke, clip: clip, visible: visible, anyWorking: anyWorking,
                attention: attention, sweepKey: sweepKey, tone: tone))
    }
}

private struct CompanionGlowBorder<Stroke: Shape, Clip: Shape>: ViewModifier {
    let stroke: Stroke
    let clip: Clip
    let visible: Bool
    let anyWorking: Bool
    let attention: Int
    let sweepKey: UUID?
    let tone: CompanionGlowTone
    @State private var sweepUntil: Date?
    @Environment(\.rafuTheme) private var theme
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let state = CompanionGlowPolicy.resolve(
            visible: visible, motionAllowed: motionAllowed, reduceMotion: reduceMotion,
            increaseContrast: contrast == .increased, reduceTransparency: reduceTransparency,
            anyWorking: anyWorking, sweepUntil: sweepUntil, now: .now)
        content
            .overlay {
                if let state {
                    border(state)
                }
            }
            .onChange(of: attention) { old, new in
                if CompanionGlowPolicy.startsSweep(oldAttention: old, newAttention: new) {
                    startSweep()
                }
            }
            .onChange(of: sweepKey) { _, key in
                if key != nil { startSweep() }
            }
            .onAppear {
                if sweepKey != nil { startSweep() }
            }
            // One wake at the end of a sweep, so the border settles to its
            // still or slow state. Cancelled when the view goes away.
            .task(id: sweepUntil) {
                guard let until = sweepUntil else { return }
                let delay = until.timeIntervalSinceNow
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                sweepUntil = nil
            }
    }

    private func startSweep() {
        sweepUntil = Date.now.addingTimeInterval(CompanionGlowPolicy.attentionSweepDuration)
    }

    private func border(_ state: CompanionGlowState) -> some View {
        let colors = CompanionGlowGradient.colors(
            for: state.fill, palette: theme.palette, tone: tone)
        // Paused while still: no frames at rest, while hidden, or under
        // Reduce Motion (`state.period` is nil then).
        return TimelineView(
            .animation(
                minimumInterval: CompanionGlowPolicy.frameInterval, paused: state.period == nil)
        ) { context in
            let angle = CompanionGlowPolicy.angle(at: context.date, period: state.period)
            // Stroked at twice the width and clipped by the surface, so the
            // visible line is `lineWidth` wide and fully inside.
            stroke
                .stroke(
                    AngularGradient(
                        colors: colors, center: .center, angle: .degrees(angle + 135)),
                    lineWidth: state.lineWidth * 2
                )
                .clipShape(clip)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Tab pill style

/// One tab option: Cider's quiet selected fill and pressed tint. Reduce
/// Transparency uses the theme's opaque selection.
struct CompanionTabOptionStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Capsule(style: .continuous).fill(selected ? selectionFill : Color.clear)
            )
            .background(
                Capsule(style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? theme.palette.accent.opacity(
                                CompanionChromeMetrics.tabPressedAccentOpacity)
                            : Color.clear)
            )
            .overlay {
                // Increase Contrast: the selected option also gets a line.
                if selected, contrast == .increased {
                    Capsule(style: .continuous)
                        .strokeBorder(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
                }
            }
            .contentShape(Capsule(style: .continuous))
    }

    private var selectionFill: Color {
        reduceTransparency
            ? theme.palette.selection
            : Color.white.opacity(CompanionChromeMetrics.tabSelectedOpacity)
    }
}

/// The capsule track behind the tab options.
struct CompanionTabTrack: ViewModifier {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .padding(CompanionChromeMetrics.tabTrackPadding)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        reduceTransparency
                            ? theme.palette.elevatedBackground
                            : Color.white.opacity(CompanionChromeMetrics.tabTrackOpacity))
            )
    }
}

// MARK: - Agent card

/// Card text for one agent, from data Rafu already holds. Pure.
nonisolated enum CompanionAgentCardContent {
    /// "Last seen just now", "Last seen 4m ago", "Last seen 2h ago",
    /// "Last seen 3d ago". Computed from the store's clock, so the text
    /// changes only when the store ticks, not on a per-second timer.
    static func lastSeenText(updatedAt: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(updatedAt))
        let ago: String
        switch seconds {
        case ..<60: return "Last seen just now"
        case ..<3600: ago = "\(Int(seconds / 60))m"
        case ..<86_400: ago = "\(Int(seconds / 3600))h"
        default: ago = "\(Int(seconds / 86_400))d"
        }
        return "Last seen \(ago) ago"
    }

    /// Cider shows a short session suffix only when two cards would read
    /// the same: same title and same provider.
    static func showsSessionSuffix(_ row: NotchAgentRow, among rows: [NotchAgentRow]) -> Bool {
        guard row.sessionSuffix != nil else { return false }
        return rows.contains { $0.id != row.id && $0.title == row.title && $0.cli == row.cli }
    }
}

/// One agent as a Cider card: icon, title (two lines), and provider; the
/// folder (and a short session suffix when titles collide); the state as a
/// glyph and a word plus when it was last seen; the last message excerpt
/// (two lines); and the sub-agents. Information only for agents outside
/// Rafu.
struct CompanionAgentCardView: View {
    let row: NotchAgentRow
    var showsSessionSuffix = false
    var now: Date
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        VStack(alignment: .leading, spacing: CompanionChromeMetrics.cardRowSpacing) {
            HStack(alignment: .top, spacing: RafuMetrics.space2) {
                AgentIconView(cli: row.cli, size: 14)
                    .accessibilityHidden(true)
                Text(row.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.primary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(row.cli.displayName)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.muted)
                    .lineLimit(1)
            }
            if let folder = folderLine {
                Text(folder)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: RafuMetrics.space1) {
                Image(systemName: row.phase.symbol)
                    .font(.system(size: 10))
                    .accessibilityHidden(true)
                Text(row.phase.label)
                    .font(
                        .system(size: 11, weight: row.phase.needsAttention ? .semibold : .regular))
                if let updatedAt = row.updatedAt {
                    Text("·")
                        .foregroundStyle(ink.muted)
                    Text(CompanionAgentCardContent.lastSeenText(updatedAt: updatedAt, now: now))
                        .font(.system(size: 10))
                        .foregroundStyle(ink.muted)
                }
            }
            .foregroundStyle(row.phase.needsAttention ? ink.accent : ink.secondary)
            .lineLimit(1)
            if let message = row.lastMessage, !message.isEmpty {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(ink.secondary)
                    .lineLimit(2)
                    .truncationMode(.tail)
            }
            CompanionSubagentsView(subagents: row.subagents)
        }
        .padding(CompanionChromeMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(
                cornerRadius: CompanionChromeMetrics.cardCornerRadius, style: .continuous
            )
            .fill(cardFill)
        )
        .overlay {
            if contrast == .increased {
                RoundedRectangle(
                    cornerRadius: CompanionChromeMetrics.cardCornerRadius, style: .continuous
                )
                .strokeBorder(theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
            }
        }
        .help("\(row.cli.displayName) in \(row.title), outside Rafu")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// The surface is opaque black, so the low white fill is already
    /// opaque on screen; Reduce Transparency still gets a solid grey.
    private var cardFill: Color {
        reduceTransparency
            ? Color(white: 0.08) : Color.white.opacity(CompanionChromeMetrics.cardFillOpacity)
    }

    private var folderLine: String? {
        let suffix = showsSessionSuffix ? row.sessionSuffix : nil
        let parts = [row.detail, suffix].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var accessibilityText: String {
        var parts = [row.title, row.cli.displayName, "outside Rafu", row.phase.label]
        if let updatedAt = row.updatedAt {
            parts.append(CompanionAgentCardContent.lastSeenText(updatedAt: updatedAt, now: now))
        }
        return parts.joined(separator: ", ")
    }
}
