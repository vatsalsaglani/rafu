import SwiftUI

/// Text colours for content drawn directly on the notch's black surface. The
/// notch is always true black, so a light theme's dark text tokens would
/// vanish on it: dark themes use their own tokens, light themes use fixed
/// light inks. Cards and fields keep the theme's own fills and text pairs,
/// which are legible against each other by construction.
struct NotchInk {
    let primary: Color
    let secondary: Color
    let muted: Color
    let accent: Color

    init(theme: RafuTheme) {
        if theme.isDark {
            primary = theme.palette.textPrimary
            secondary = theme.palette.textSecondary
            muted = theme.palette.textMuted
        } else {
            primary = Color.white.opacity(0.92)
            secondary = Color.white.opacity(0.68)
            muted = Color.white.opacity(0.5)
        }
        accent = theme.palette.accent
    }
}

/// The notch companion's content (terminal-notch-hud.md NC-B, rebuilt like
/// Cider's notch): a strip with the mascot and a compact status; hovering
/// (or clicking) opens a fixed-size panel of tabs — Ensembles, Up next, Now
/// Playing, Usage. PRESENTATION ONLY — every value shown here already lives on
/// `NotchCompanionModel`; this view never touches a `WorkspaceSession`
/// directly. The strip belongs to no scene, so the theme is injected into
/// the environment manually, mirroring `NotchHUDView`.
struct NotchCompanionView: View {
    let model: NotchCompanionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var theme: RafuTheme { model.theme }

    var body: some View {
        VStack(spacing: 0) {
            if model.surface == .island {
                CompanionIslandWingsView(model: model)
            } else {
                CompanionWingsView(model: model)
            }
            if model.isPanelOpen {
                CompanionPanelView(model: model)
                    .transition(panelTransition)
            }
        }
        // The open notch panel's window is wider by both shoulders
        // (`NotchCompanionGeometry.peekPanelFrame`); the content stays
        // between them.
        .padding(.horizontal, contentInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surfaceColor)
        .overlay(alignment: .bottom) {
            if contrast == .increased, model.surface != .island, !glowVisible {
                Rectangle()
                    .fill(theme.palette.borderStrong)
                    .frame(height: RafuMetrics.hairline)
            }
        }
        // The island capsule floats free of the screen edge, so Increase
        // Contrast outlines all of it instead of drawing a bottom rule.
        .overlay {
            if contrast == .increased, model.surface == .island, !glowVisible {
                islandShape.strokeBorder(
                    theme.palette.borderStrong, lineWidth: RafuMetrics.hairline)
            }
        }
        .modifier(
            CompanionShellModifier(
                model: model, islandShape: islandShape, outlineLimits: outlineLimits,
                glowVisible: glowVisible)
        )
        .onHover { inside in
            if inside {
                model.hoverMoved()
            } else {
                model.hoverExited()
            }
        }
        .onKeyPress(.escape) {
            model.escapePressed()
            return .handled
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18),
            value: model.hoverState
        )
        .rafuTheme(theme)
        // The strip stays ordered front behind a locked screen; this stops
        // the mascot, the playback bars, and the gradient border there.
        .rafuMotionScope()
    }

    /// Always true black (terminal-notch-hud.md, "Resting": "housing-black
    /// presence"): on a notched screen it must merge with the housing, and the
    /// floating pill on a plain display keeps the same look.
    private var surfaceColor: Color { Color.black }

    /// The gradient border shows while the panel is open (Cider: expanded),
    /// and on the notch strip or the pill while a terminal needs attention
    /// (Cider: peek). The resting notch strip does not widen for attention,
    /// so the border does not wait for `isStripExpanded`.
    private var glowVisible: Bool {
        model.isPanelOpen || (model.surface != .island && model.attentionCount > 0)
    }

    /// The notch and the plain-display pill hang from the screen top: Cider's
    /// outline, with concave shoulders only while the panel is open, so the
    /// panel opens out of the strip. The island keeps all-round corners.
    private var outlineLimits: CompanionOutlineLimits {
        model.isPanelOpen ? .open : .closed
    }

    private var contentInset: CGFloat {
        model.surface == .island ? 0 : outlineLimits.shoulder
    }

    /// On an island every corner is round: a capsule at rest (radius half
    /// the height), a rounded card when open — the same language as the
    /// system Dynamic Island it sits behind.
    private var islandShape: UnevenRoundedRectangle {
        let radius = model.isPanelOpen ? model.islandOpenCornerRadius : model.stripHeight / 2
        return UnevenRoundedRectangle(
            topLeadingRadius: radius,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: radius,
            style: .continuous
        )
    }

    /// Reduce Motion: cross-fade only, no slide (matching `NotchHUDView`'s
    /// transition rule).
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

/// Clips the companion to its shell and draws the gradient border: the
/// island's rounded rectangle, or the hanging `CompanionOutline` (the border
/// leaves out the top edge, which meets the housing or the menu bar).
private struct CompanionShellModifier: ViewModifier {
    let model: NotchCompanionModel
    let islandShape: UnevenRoundedRectangle
    let outlineLimits: CompanionOutlineLimits
    let glowVisible: Bool

    func body(content: Content) -> some View {
        let working = model.agentSummary.working > 0
        let attention = model.attentionCount + model.agentSummary.attention
        if model.surface == .island {
            content
                .companionGlowBorder(
                    stroke: islandShape, clip: islandShape, visible: glowVisible,
                    anyWorking: working, attention: attention
                )
                .clipShape(islandShape)
        } else {
            content
                .companionGlowBorder(
                    stroke: CompanionOutline(limits: outlineLimits, openTop: true),
                    clip: CompanionOutline(limits: outlineLimits),
                    visible: glowVisible, anyWorking: working, attention: attention
                )
                .clipShape(CompanionOutline(limits: outlineLimits))
        }
    }
}

/// The wings row (terminal-notch-hud.md, "Resting"): the mascot (or the plain
/// Rafu mark) and the compact status (`CompanionRestingStatus`). The resting
/// notch strip has ONE wing, left of the notch, with the mark and the status
/// side by side in it: the physical housing hides about 16pt beside the
/// notch, and on macOS 27 the menu bar's "«" overflow chevron sits right of
/// the notch, where a right wing would cover it. The wider strip (hover) and
/// the pill on a plain display put the mark on the left and the status on
/// the right. The row IS the click target — since
/// `NotchHUDPanel.clickThroughRegions` is always empty for this panel (see
/// `NotchCompanionModel.presentPanel`), a single tap on the whole row covers
/// the full strip, notch gap included.
struct CompanionWingsView: View {
    let model: NotchCompanionModel

    var body: some View {
        Group {
            if model.hasPhysicalNotch, !model.isStripExpanded {
                HStack(spacing: 0) {
                    restingLeadingWing
                    // The notch housing.
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 0) {
                    leftWing
                    Spacer(minLength: 0)
                    CompanionRestingStatus(model: model, wide: true)
                        .padding(.trailing, RafuMetrics.space2 + 2)
                }
            }
        }
        .frame(height: max(model.stripHeight, 1))
        .contentShape(Rectangle())
        .onTapGesture { model.clicked() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryLabel)
        .accessibilityHint(
            model.isPanelOpen ? "Activates to pin or unpin" : "Activates to open the notch panel"
        )
        .accessibilityAddTraits(.isButton)
    }

    /// The resting notch strip's only wing: the mark and the status in one
    /// row, kept to the part of the wing the housing does not hide.
    private var restingLeadingWing: some View {
        HStack(alignment: .center, spacing: RafuMetrics.space2 - 2) {
            CompanionLeadingMarkView(model: model)
            CompanionRestingStatus(model: model, wide: false)
        }
        .padding(.leading, RafuMetrics.space2 - 2)
        .frame(
            width: NotchCompanionGeometry.restingLeadingWingWidth
                - NotchCompanionGeometry.housingHiddenInset,
            alignment: .leading
        )
        .lineLimit(1)
    }

    /// The mascot on the wider strip and the pill; a playing-music indicator
    /// joins it once the strip is wide enough that the indicator is not
    /// behind the housing.
    private var leftWing: some View {
        HStack(spacing: RafuMetrics.space1) {
            CompanionLeadingMarkView(model: model)
            if showsPlaybackIndicator {
                NotchPlaybackIndicator()
            }
        }
        .padding(.leading, RafuMetrics.space2 - 2)
    }

    private var showsPlaybackIndicator: Bool {
        model.nowPlaying.playing && model.visibleSections.contains(.nowPlaying)
            && (model.isStripExpanded || !model.hasPhysicalNotch)
    }

    /// "Rafu — 3 agents, 1 needs you, 2 editors open" — prefixed with the app
    /// name because this element has no window title or menu-bar icon a
    /// VoiceOver user could otherwise anchor it to.
    private var summaryLabel: String {
        let editors = model.editorRows.count
        var parts = [model.agentSummary.spokenSummary]
        if !AgentRequestStore.shared.pending.isEmpty { parts.append("Needs approval") }
        parts.append("\(editors) editor\(editors == 1 ? "" : "s") open")
        let attention = model.attentionCount
        if attention > 0 {
            parts.append(
                "\(attention) terminal\(attention == 1 ? "" : "s") needing attention")
        }
        return "Rafu — \(parts.joined(separator: ", "))"
    }
}

/// The strip's compact status: attention first (a dot and count), then live
/// agents, then (when nothing is running) open editors. `wide` (the wider
/// strip and the pill) shows every item with its icon. The resting notch
/// strip shows only the first of the three, so it fits beside the mark in
/// the one leading wing.
struct CompanionRestingStatus: View {
    let model: NotchCompanionModel
    let wide: Bool
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let summary = model.agentSummary
        HStack(spacing: RafuMetrics.space2 - 2) {
            if !AgentRequestStore.shared.pending.isEmpty {
                Label("Needs approval", systemImage: "exclamationmark.bubble")
                    .labelStyle(.iconOnly)
                    .help("Needs approval")
            } else if model.attentionCount > 0 {
                HStack(spacing: 3) {
                    Circle()
                        .fill(ink.accent)
                        .frame(width: 6, height: 6)
                    Text("\(model.attentionCount)")
                        .foregroundStyle(ink.accent)
                }
            }
            if summary.live > 0, wide || model.attentionCount == 0 {
                HStack(spacing: 3) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 9, weight: .medium))
                    Text(Self.countText(summary.live))
                }
                .foregroundStyle(ink.primary)
            }
            if wide || (summary.live == 0 && model.attentionCount == 0) {
                HStack(spacing: 3) {
                    if wide {
                        Image(systemName: "macwindow")
                            .font(.system(size: 9, weight: .medium))
                    }
                    Text("\(model.editorRows.count)")
                }
                .foregroundStyle(ink.secondary)
            }
        }
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .lineLimit(1)
    }

    private static func countText(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }
}

/// The strip's leading item, shared by the notch wings and the island
/// capsule: the voice orb while a voice session is open, else the mascot,
/// else the plain Rafu mark.
struct CompanionLeadingMarkView: View {
    let model: NotchCompanionModel
    private var voice = VoiceSession.shared

    init(model: NotchCompanionModel) { self.model = model }

    var body: some View {
        // An open voice session takes the mascot's place, so the strip
        // keeps its width (voice-control.md).
        if voice.blobState != .idle {
            VoiceNotchOrb(session: voice)
        } else if model.isMascotEnabled {
            RafuMascotView(
                state: model.mascotState, engaged: model.isStripExpanded, size: 20,
                claimBounce: model.claimMascotBounce)
        } else {
            RafuBrandMarkView()
                .frame(width: 14, height: 14)
        }
    }
}

/// The capsule behind a system Dynamic Island: the leading mark in the left
/// lobe, one usage ring in the right lobe, and NOTHING in the middle, where
/// the system island draws its own activity. The percentage joins the ring
/// once the capsule is wide (hover) or the card is open. A click or a
/// touch-screen tap anywhere on the capsule opens or closes the card.
struct CompanionIslandWingsView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    /// Outer padding of each lobe's content from the capsule's ends.
    private static let lobePadding: CGFloat = 12
    private static let ringSize: CGFloat = 16

    var body: some View {
        let glance = model.islandUsageGlance
        let padding = Self.lobePadding
        HStack(spacing: 0) {
            CompanionLeadingMarkView(model: model)
                .padding(.leading, padding)
            Spacer(minLength: 0)
            Group {
                if AgentRequestStore.shared.pending.isEmpty {
                    usageLobe(glance)
                } else {
                    Label("Needs approval", systemImage: "exclamationmark.bubble")
                        .labelStyle(.iconOnly)
                        .help("Needs approval")
                }
            }
            .padding(.trailing, padding)
        }
        .frame(height: max(model.stripHeight, 1))
        .contentShape(Rectangle())
        .onTapGesture { model.clicked() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Rafu, "
                + (AgentRequestStore.shared.pending.isEmpty
                    ? glance?.spokenLabel ?? "no usage data" : "Needs approval")
        )
        .accessibilityHint(
            model.isPanelOpen
                ? "Activates to close the panel" : "Activates to open the panel"
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.clicked() }
    }

    private var ink: UsageCardInk {
        .notch(
            theme: theme, palette: model.usageRingPalette,
            increasedContrast: contrast == .increased)
    }

    private func usageLobe(_ glance: NotchIslandUsageGlance?) -> some View {
        let showsPercent = glance != nil && (model.isStripExpanded || model.isPanelOpen)
        return HStack(spacing: RafuMetrics.space1) {
            if showsPercent, let glance {
                Text(glance.percentText)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)
                    .fixedSize()
            }
            RafuProgressRing(
                arcs: [
                    RafuProgressRing.Arc(
                        fraction: glance?.fraction,
                        color: ink.color(for: glance?.tone ?? .primary),
                        track: ink.trackColor)
                ],
                size: Self.ringSize, lineWidth: 2.5, gap: 0
            )
            .overlay {
                // Critical is never colour alone: a glyph inside the ring.
                if glance?.level == .critical {
                    Text("!")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(ink.warningTint(for: .critical))
                        .accessibilityHidden(true)
                }
            }
        }
    }
}

/// One section host for every companion surface (`CompanionHost`): a tab
/// row over the selected section's content. The notch panel, the island
/// card, and the menu bar card all use it, so each section has one view.
/// Fixed height, set by the window or popover; each section scrolls inside
/// it. The island card offers Usage only, so it has no tab row; the Usage
/// header carries its close button instead. The notch panel's tab row ends
/// in the pin button; the menu bar card's ends in a close button.
struct CompanionSectionHost: View {
    let model: NotchCompanionModel
    let host: CompanionHost
    /// Closes the menu bar card. `nil` on the notch panel and island card,
    /// which close through the model.
    var close: (@MainActor () -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            if host != .islandCard {
                CompanionTabBar(model: model, host: host, close: close)
            }
            Group {
                if host == .islandCard && !AgentRequestStore.shared.pending.isEmpty {
                    VStack(alignment: .leading) {
                        Button("Close") { model.escapePressed() }
                        CompanionUpNextSectionView(model: model, host: host)
                    }
                } else {
                    switch model.selection(for: host) {
                    case .ensembles: CompanionEnsemblesSectionView(model: model, host: host)
                    case .upNext: CompanionUpNextSectionView(model: model, host: host)
                    case .nowPlaying: CompanionNowPlayingSectionView(model: model)
                    case .usage: CompanionUsageSectionView(model: model, host: host)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The open notch panel (or island card): the shared section host.
struct CompanionPanelView: View {
    let model: NotchCompanionModel

    var body: some View {
        CompanionSectionHost(model: model, host: CompanionHost.panel(on: model.surface))
    }
}

/// Cider's pill picker (`CompanionChromeMetrics`), as a row of tab
/// buttons in one capsule track, then the pin or close button. Each tab is
/// a real button with a title for VoiceOver; counts are text, not colour
/// alone. Left and Right arrows move between tabs; on the menu bar card
/// Command-1 to Command-3 select a tab.
struct CompanionTabBar: View {
    let model: NotchCompanionModel
    let host: CompanionHost
    var close: (@MainActor () -> Void)? = nil
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        let sections = model.sections(for: host)
        let equalWidths = CompanionChromeMetrics.usesEqualTabWidths(tabCount: sections.count)
        HStack(spacing: CompanionChromeMetrics.tabAccessorySpacing) {
            HStack(spacing: CompanionChromeMetrics.tabOptionSpacing) {
                ForEach(Array(sections.enumerated()), id: \.element) { index, section in
                    tab(section, index: index, equalWidth: equalWidths)
                }
            }
            .frame(maxWidth: equalWidths ? .infinity : nil)
            .modifier(CompanionTabTrack())
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Sections")
            if !equalWidths {
                Spacer(minLength: 0)
            }
            trailingControl
        }
        .padding(.horizontal, CompanionChromeMetrics.tabBarHorizontalPadding)
        .padding(.top, CompanionChromeMetrics.tabBarTopPadding)
        .padding(.bottom, CompanionChromeMetrics.tabBarBottomPadding)
        .onKeyPress(.leftArrow) { step(-1, in: sections) }
        .onKeyPress(.rightArrow) { step(1, in: sections) }
    }

    private func step(_ offset: Int, in sections: [NotchSection]) -> KeyPress.Result {
        let next = CompanionMenuSelection.step(
            from: model.selection(for: host), in: sections, by: offset)
        model.select(next, host: host)
        return .handled
    }

    @ViewBuilder
    private var trailingControl: some View {
        if host == .menuBar {
            Button {
                close?()
            } label: {
                accessoryLabel(symbol: "xmark", color: ink.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")
            .accessibilityLabel("Close")
        } else {
            Button {
                model.clicked()
            } label: {
                accessoryLabel(
                    symbol: model.hoverState == .pinned ? "pin.fill" : "pin",
                    color: model.hoverState == .pinned ? ink.accent : ink.secondary)
            }
            .buttonStyle(.plain)
            .help(model.hoverState == .pinned ? "Unpin the notch" : "Pin the notch open")
            .accessibilityLabel(model.hoverState == .pinned ? "Unpin notch" : "Pin notch")
        }
    }

    private func accessoryLabel(symbol: String, color: Color) -> some View {
        let size = CompanionChromeMetrics.tabAccessorySize
        return Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .contentShape(Circle())
    }

    private func tab(_ section: NotchSection, index: Int, equalWidth: Bool) -> some View {
        let selected = model.selection(for: host) == section
        let badge = badgeText(for: section)
        return Button {
            model.select(section, host: host)
        } label: {
            HStack(spacing: RafuMetrics.space1) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(section.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                if let badge {
                    Text(badge.text)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(badge.isAttention ? ink.accent : ink.muted)
                }
            }
            .foregroundStyle(selected ? ink.primary : ink.secondary)
            .padding(.horizontal, CompanionChromeMetrics.tabOptionHorizontalPadding)
            .frame(maxWidth: equalWidth ? .infinity : nil)
            .frame(height: CompanionChromeMetrics.tabOptionHeight(for: host))
        }
        .buttonStyle(CompanionTabOptionStyle(selected: selected))
        .help(section.title)
        .modifier(CompanionTabShortcut(index: index, enabled: host == .menuBar))
        .accessibilityLabel(section.title + (badge.map { ", " + $0.spoken } ?? ""))
        .accessibilityAddTraits(
            selected ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton)
    }

    private struct Badge {
        let text: String
        let spoken: String
        let isAttention: Bool
    }

    private func badgeText(for section: NotchSection) -> Badge? {
        switch section {
        case .ensembles:
            let live = model.agentSummary.live
            return live > 0
                ? Badge(text: "\(live)", spoken: "\(live) running", isAttention: false) : nil
        case .upNext:
            let waiting = model.upNextRows(for: host).count
            return waiting > 0
                ? Badge(text: "\(waiting)", spoken: "\(waiting) waiting", isAttention: true) : nil
        case .nowPlaying, .usage:
            return nil
        }
    }
}

/// Command-1 to Command-9 on a tab, only on the menu bar card, whose
/// popover is key while open; the notch panel never takes the shortcut.
private struct CompanionTabShortcut: ViewModifier {
    let index: Int
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, index < 9 {
            content.keyboardShortcut(
                KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        } else {
            content
        }
    }
}

/// The editors-list filter field (terminal-notch-hud.md NC-B,
/// "Search/filter") — narrows `model.editorRows` by workspace name OR git
/// branch as the user types, through `model.setSearchQuery(_:)`. Shown only
/// while `model.isSearchFieldVisible`; pinned above the scrolling results
/// (`NotchCompanionView`'s wiring), so it never scrolls with them. Its own
/// focus is the SECOND path (alongside a feed card's reply field) that can
/// make the panel key — routed through `model.engageSearch()`/
/// `disengageSearch()`, never `allowsKeyStatus` directly (see
/// `NotchCompanionModel.updateKeyStatus()`).
struct CompanionSearchFieldView: View {
    @Bindable var model: NotchCompanionModel
    @FocusState private var searchFocused: Bool
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
            TextField("Filter editors…", text: queryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
                .accessibilityLabel("Filter editors by name or branch")
            if !model.searchQuery.isEmpty {
                Button {
                    model.setSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityLabel("Clear filter")
            }
        }
        .rafuField(isFocused: searchFocused)
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
        .onChange(of: searchFocused) { _, focused in
            if focused {
                model.engageSearch()
            } else {
                model.disengageSearch()
            }
        }
        // Screenshot-verified gap: a ROW click (`model.focusEditor(_:)`)
        // brings a DIFFERENT real window to key status, which resigns this
        // panel's key status and fires `panelDidResignKey()` →
        // `clearKeyEngagement()` — but that clears `model.isSearchEngaged`
        // from OUTSIDE this view, and SwiftUI's `@FocusState` does NOT
        // reset to `false` on its own just because the window is no longer
        // key. Left unhandled, `searchFocused` stays stuck at `true`
        // forever after, so a later click never produces a false→true
        // transition, `onChange(of: searchFocused)` never fires again, and
        // the field becomes permanently unfocusable until the panel
        // round-trips through `.resting` (which recreates this view).
        // Mirroring the model's own external state back into the
        // `@FocusState` closes that gap.
        .onChange(of: model.isSearchEngaged) { _, engaged in
            if !engaged { searchFocused = false }
        }
    }

    private var queryBinding: Binding<String> {
        Binding(
            get: { model.searchQuery },
            set: { model.setSearchQuery($0) }
        )
    }
}

/// One editor window's row: name + window number, the git one-liner (hidden
/// when no repository is open), and terminal chips — each chip shown only
/// when its count is non-zero (terminal-notch-hud.md, "Peek", item 2).
struct CompanionEditorRowView: View {
    let row: CompanionEditorRow
    let focus: () -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Button(action: focus) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: RafuMetrics.space2) {
                    Text(row.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("#\(row.windowNumber)")
                        .font(.system(size: 10))
                        .foregroundStyle(theme.palette.textMuted)
                    Spacer(minLength: 0)
                    chips
                }
                if let gitSummary = row.gitSummary {
                    Text(gitSummary)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, RafuMetrics.space2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(theme.palette.cardBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        theme.palette.borderSubtle.opacity(0.5), lineWidth: RafuMetrics.hairline)
            )
        }
        .buttonStyle(.plain)
        .help("Focus this editor window")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint("Activates to focus this editor window")
    }

    @ViewBuilder
    private var chips: some View {
        HStack(spacing: RafuMetrics.space1) {
            if row.runningCount > 0 {
                chip("▶ \(row.runningCount)", theme.palette.textSecondary)
            }
            if row.attentionCount > 0 {
                chip("● \(row.attentionCount)", theme.palette.accent)
            }
            if row.exitedCount > 0 {
                chip("◼ \(row.exitedCount)", theme.palette.textMuted)
            }
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(color)
    }

    private var accessibilityText: String {
        var parts = [row.name, "window \(row.windowNumber)"]
        if let gitSummary = row.gitSummary { parts.append(gitSummary) }
        if row.runningCount > 0 { parts.append("\(row.runningCount) running") }
        if row.attentionCount > 0 { parts.append("\(row.attentionCount) needing attention") }
        if row.exitedCount > 0 { parts.append("\(row.exitedCount) exited") }
        return parts.joined(separator: ", ")
    }
}

/// The cross-window attention feed (terminal-notch-hud.md NC-C, "Peek", item
/// 3): one card per session currently in `.bell`, newest first, shown below
/// the editors list whenever the peek panel is open. Renders nothing when
/// empty — unlike the Ensembles list, the feed has no empty state to
/// reserve space for; the resting strip's right-wing dot is already the
/// "anything waiting?" signal.
struct CompanionAttentionFeedView: View {
    let model: NotchCompanionModel

    var excluding: Set<UUID> = []

    var body: some View {
        let items = model.feedItems.filter { !excluding.contains($0.sessionID) }
        if !items.isEmpty {
            VStack(spacing: CompanionChromeMetrics.sectionSpacing) {
                ForEach(items) { item in
                    CompanionFeedCardView(model: model, item: item)
                }
            }
            .padding(.horizontal, CompanionChromeMetrics.contentHorizontalPadding)
            .frame(maxWidth: .infinity, alignment: .top)
        }
    }
}

/// One session's attention card: session-color border (the same
/// Terminals-panel/drop-down card language), display name + editor name +
/// relative time, the bounded snippet, an inline reply field + Send, and an
/// "Open" button that reveals the session's tab. Reuses `NotchHUDView`'s
/// expanded snippet/reply visual treatment verbatim so the two surfaces read
/// as one companion, restyled only by their container.
///
/// The reply field's focus is the FIRST path that ever engages
/// `NotchCompanionModel`'s panel key status (terminal-notch-hud.md NC-C) —
/// mirroring `NotchHUDView`'s own `replyFocused` →
/// `engageReply()`/`disengageReply()` recipe exactly.
struct CompanionFeedCardView: View {
    let model: NotchCompanionModel
    let item: CompanionFeedItem
    @State private var replyText = ""
    @FocusState private var replyFocused: Bool
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            header
            snippetBlock
            replyRow
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                .fill(theme.palette.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                .strokeBorder(borderColor, lineWidth: borderWidth)
        )
        .onChange(of: replyFocused) { _, focused in
            if focused {
                model.engageReply()
            } else {
                model.disengageReply()
            }
        }
    }

    /// The session color IS the border, matching `NotchHUDView.borderColor`
    /// and the Terminals panel cards; Increase Contrast always gets a
    /// defined border.
    private var borderColor: Color {
        if let color = item.color {
            return theme.palette.color(for: color)
        }
        return contrast == .increased
            ? theme.palette.borderStrong
            : theme.palette.borderSubtle.opacity(0.6)
    }

    private var borderWidth: CGFloat {
        item.color != nil ? 2 : RafuMetrics.hairline
    }

    private var header: some View {
        HStack(alignment: .top, spacing: RafuMetrics.space2) {
            // Decorative — the bell/attention state is spoken through
            // `accessibilityLabel` below, not this glyph (VoiceOver: "name +
            // editor + 'needs attention'", terminal-notch-hud.md NC-E).
            Image(systemName: TerminalSessionPresentation.symbol(.bell))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(item.editorName)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.palette.textMuted)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(item.title), \(item.editorName), needs attention")
            Spacer(minLength: RafuMetrics.space2)
            Text(item.timestamp, style: .relative)
                .font(.system(size: 10))
                .foregroundStyle(theme.palette.textMuted)
            Button("Open") {
                model.revealFeedSession(item.sessionID)
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            .help("Reveal this terminal in its window")
            .accessibilityHint("Activates to reveal the terminal tab and clear this card")
        }
    }

    /// The full bounded snippet — same one-line-per-row, monospaced
    /// treatment as `NotchHUDView.snippetBlock(_:)`, filled with
    /// `fieldBackground` (rather than `cardBackground`, which this card's
    /// own shell already uses) so the output area still reads as distinct
    /// content inside the card.
    private var snippetBlock: some View {
        let lines = item.snippet.split(separator: "\n", omittingEmptySubsequences: false)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(String(line))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textPrimary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, RafuMetrics.space2)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                .fill(theme.palette.fieldBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recent output")
    }

    private var replyRow: some View {
        HStack(spacing: RafuMetrics.space2) {
            TextField("Reply to \(item.title)…", text: $replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($replyFocused)
                .onSubmit(send)
                .padding(.horizontal, RafuMetrics.space2)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                        .fill(theme.palette.fieldBackground)
                )
                .accessibilityLabel("Reply to \(item.title)")
            Button("Send", action: send)
                .buttonStyle(RafuProminentButtonStyle(compact: true))
                .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send the reply to that terminal")
        }
    }

    private func send() {
        model.sendReply(replyText, to: item.sessionID)
        replyText = ""
    }
}
