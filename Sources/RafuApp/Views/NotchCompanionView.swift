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
            CompanionWingsView(model: model)
            if model.isPanelOpen {
                CompanionPanelView(model: model)
                    .transition(panelTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(surfaceColor)
        .overlay(alignment: .bottom) {
            if contrast == .increased {
                Rectangle()
                    .fill(theme.palette.borderStrong)
                    .frame(height: RafuMetrics.hairline)
            }
        }
        .clipShape(shellShape)
        .onHover { hovering in
            if hovering { model.hoverEntered() } else { model.hoverExited() }
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
    }

    /// Always true black (terminal-notch-hud.md, "Resting": "housing-black
    /// presence"): on a notched screen it must merge with the housing, and the
    /// floating pill on a plain display keeps the same look.
    private var surfaceColor: Color { Color.black }

    /// Bottom-rounded, flush with the screen's top edge — the strip reads
    /// as hanging from the physical housing, matching `NotchHUDView`'s
    /// `hudShape` technique.
    private var shellShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: RafuMetrics.radiusPanel,
            bottomTrailingRadius: RafuMetrics.radiusPanel,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    /// Reduce Motion: cross-fade only, no slide (matching `NotchHUDView`'s
    /// transition rule).
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

/// The wings row (terminal-notch-hud.md, "Resting"): the mascot (or the plain
/// Rafu mark) on the left, the compact status on the right — a dot and count
/// when something needs you, the live agent count, and the open-editor count
/// when nothing else is running. The physical housing hides about 16pt beside
/// the notch, so the resting strip keeps to one short item per side; the wider
/// strip (attention, hover) and the pill on a plain display show everything.
/// The row IS the click target — since `NotchHUDPanel.clickThroughRegions` is
/// always empty for this panel (see `NotchCompanionModel.presentPanel`), a
/// single tap on the whole row covers the full strip, notch gap included.
struct CompanionWingsView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        HStack(spacing: 0) {
            leftWing
            Spacer(minLength: 0)
            rightWing
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

    /// The mascot, alone at rest; a playing-music indicator joins it once the
    /// strip is wide enough that the indicator is not behind the housing.
    private var leftWing: some View {
        HStack(spacing: RafuMetrics.space1) {
            if model.isMascotEnabled {
                RafuMascotView(
                    state: model.mascotState, visible: true, size: 20,
                    claimBounce: model.claimMascotBounce)
            } else {
                RafuBrandMarkView()
                    .frame(width: 14, height: 14)
            }
            if showsPlaybackIndicator {
                NotchPlaybackIndicator(motionActive: true)
            }
        }
        .padding(.leading, RafuMetrics.space2 - 2)
    }

    private var showsPlaybackIndicator: Bool {
        model.nowPlaying.playing && model.visibleSections.contains(.nowPlaying)
            && (model.isStripExpanded || !model.hasPhysicalNotch)
    }

    /// Attention first, then agents, then (when nothing is running) editors.
    private var rightWing: some View {
        let summary = model.agentSummary
        let wide = model.isStripExpanded || !model.hasPhysicalNotch
        return HStack(spacing: RafuMetrics.space2 - 2) {
            if model.attentionCount > 0 {
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
            if summary.live == 0 || wide {
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
        .padding(.trailing, RafuMetrics.space2 + 2)
    }

    private static func countText(_ count: Int) -> String {
        count > 99 ? "99+" : String(count)
    }

    /// "Rafu — 3 agents, 1 needs you, 2 editors open" — prefixed with the app
    /// name because this element has no window title or menu-bar icon a
    /// VoiceOver user could otherwise anchor it to.
    private var summaryLabel: String {
        let editors = model.editorRows.count
        var parts = [model.agentSummary.spokenSummary]
        parts.append("\(editors) editor\(editors == 1 ? "" : "s") open")
        let attention = model.attentionCount
        if attention > 0 {
            parts.append(
                "\(attention) terminal\(attention == 1 ? "" : "s") needing attention")
        }
        return "Rafu — \(parts.joined(separator: ", "))"
    }
}

/// The open panel: a tab row (one tab per section the person turned on, plus
/// a pin button) over the selected section's content. Fixed height, set by
/// the window frame; each section scrolls inside it.
struct CompanionPanelView: View {
    let model: NotchCompanionModel

    var body: some View {
        VStack(spacing: 0) {
            CompanionTabBar(model: model)
            Group {
                switch model.selectedSection {
                case .ensembles: CompanionEnsemblesSectionView(model: model)
                case .upNext: CompanionUpNextSectionView(model: model)
                case .nowPlaying: CompanionNowPlayingSectionView(model: model)
                case .usage: CompanionUsageSectionView(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Cider's pill picker, as a row of tab buttons. Each tab is a real button
/// with a title for VoiceOver; counts are text, not colour alone.
struct CompanionTabBar: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    private var ink: NotchInk { NotchInk(theme: theme) }

    var body: some View {
        HStack(spacing: RafuMetrics.space1) {
            ForEach(model.visibleSections) { section in
                tab(section)
            }
            Spacer(minLength: RafuMetrics.space2)
            Button {
                model.clicked()
            } label: {
                Image(systemName: model.hoverState == .pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(model.hoverState == .pinned ? ink.accent : ink.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(model.hoverState == .pinned ? "Unpin the notch" : "Pin the notch open")
            .accessibilityLabel(model.hoverState == .pinned ? "Unpin notch" : "Pin notch")
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, RafuMetrics.space2)
    }

    private func tab(_ section: NotchSection) -> some View {
        let selected = model.selectedSection == section
        let badge = badgeText(for: section)
        return Button {
            model.select(section)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: section.symbol)
                    .font(.system(size: 10, weight: .medium))
                Text(section.title)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
                if let badge {
                    Text(badge.text)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(badge.isAttention ? ink.accent : ink.muted)
                }
            }
            .foregroundStyle(selected ? ink.primary : ink.secondary)
            .padding(.horizontal, RafuMetrics.space2)
            .frame(height: 24)
            .background(
                Capsule(style: .continuous)
                    .fill(selected ? theme.palette.selection : Color.clear)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
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
            let waiting = model.upNextRows.count
            return waiting > 0
                ? Badge(text: "\(waiting)", spoken: "\(waiting) waiting", isAttention: true) : nil
        case .nowPlaying, .usage:
            return nil
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

    var body: some View {
        if !model.feedItems.isEmpty {
            VStack(spacing: RafuMetrics.space2) {
                ForEach(model.feedItems) { item in
                    CompanionFeedCardView(model: model, item: item)
                }
            }
            .padding(.horizontal, RafuMetrics.space3)
            .padding(.bottom, RafuMetrics.space3)
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
