import SwiftUI

/// The notch companion strip's content (terminal-notch-hud.md NC-B):
/// resting shows only the wings row; hovering (dwell) or clicking expands
/// it downward into the editors list. PRESENTATION ONLY — every value shown
/// here already lives on `NotchCompanionModel`; this view never touches a
/// `WorkspaceSession` directly. The strip belongs to no scene, so the theme
/// is injected into the environment manually, mirroring `NotchHUDView`.
struct NotchCompanionView: View {
    let model: NotchCompanionModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private var theme: RafuTheme { model.theme }

    var body: some View {
        VStack(spacing: 0) {
            CompanionWingsView(model: model)
            if model.hoverState != .resting {
                // Internal scroll: the panel's HEIGHT is capped by
                // `NotchCompanionGeometry.peekPanelFrame` (many editor
                // windows/feed cards must not march the panel off the
                // bottom of the screen), so overflow scrolls here instead
                // of growing the window.
                ScrollView(.vertical) {
                    VStack(spacing: RafuMetrics.space2) {
                        CompanionUsageStripView(model: model)
                        CompanionEditorsListView(model: model)
                        CompanionAttentionFeedView(model: model)
                    }
                    .frame(maxWidth: .infinity, alignment: .top)
                }
                .scrollIndicators(.automatic)
                .transition(listTransition)
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
        .environment(\.rafuTheme, theme)
    }

    /// Always true black (terminal-notch-hud.md, "Resting": "housing-black
    /// presence") — unlike `NotchHUDView`'s HUD, which also appears on
    /// non-notch screens and keeps a themed fallback there, the companion
    /// strip only ever exists on a notched screen
    /// (`NotchCompanionModel.activateIfEnabled()` tears it down otherwise),
    /// so there is no non-notch branch to account for.
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
    private var listTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }
}

/// The always-present wings row (terminal-notch-hud.md, "Resting"): left
/// wing is the Rafu mark + open-editor count, right wing is the attention
/// dot + count (hidden entirely when calm). The row IS the click target —
/// see `NotchHUDPanel.clickThroughRegions`/`NotchHUDPassthroughHostingView`
/// for why a tap landing in the notch gap between the wings never reaches
/// this gesture at all (AppKit already refused the hit test upstream), so a
/// single `onTapGesture` on the whole row is equivalent to "wings only".
struct CompanionWingsView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: 0) {
            leftWing
            Spacer(minLength: 0)
            rightWing
        }
        .frame(height: max(model.bandInset, 1))
        .contentShape(Rectangle())
        .onTapGesture { model.clicked() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summaryLabel)
        .accessibilityHint(
            model.hoverState == .resting
                ? "Activates to show open editors" : "Activates to collapse"
        )
        .accessibilityAddTraits(.isButton)
    }

    private var leftWing: some View {
        HStack(spacing: RafuMetrics.space1) {
            RafuBrandMarkView()
                .frame(width: 14, height: 14)
            Text("\(model.editorRows.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(theme.palette.textPrimary)
        }
        .frame(width: NotchCompanionGeometry.wingWidth, alignment: .leading)
        .padding(.leading, RafuMetrics.space2)
    }

    /// Nothing when calm — the right wing only renders content once a
    /// session needs attention (terminal-notch-hud.md, "Resting": "nothing
    /// when calm").
    private var rightWing: some View {
        HStack(spacing: RafuMetrics.space1) {
            if model.attentionCount > 0 {
                Circle()
                    .fill(theme.palette.accent)
                    .frame(width: 6, height: 6)
                Text("\(model.attentionCount)")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.accent)
            }
        }
        .frame(width: NotchCompanionGeometry.wingWidth, alignment: .trailing)
        .padding(.trailing, RafuMetrics.space2)
    }

    /// "Rafu — N editors open" / "..., N terminals needing attention"
    /// (terminal-notch-hud.md NC-E) — prefixed with the app name because
    /// this element has no window title or menu-bar icon a VoiceOver user
    /// could otherwise anchor it to.
    private var summaryLabel: String {
        let count = model.editorRows.count
        let editors = "\(count) editor\(count == 1 ? "" : "s") open"
        guard model.attentionCount > 0 else { return "Rafu — \(editors)" }
        let attention = model.attentionCount
        return
            "Rafu — \(editors), \(attention) terminal\(attention == 1 ? "" : "s") needing attention"
    }
}

/// The peek panel's usage strip (terminal-notch-hud.md NC-D, "Peek", item
/// 1): one muted line per agent that has data, e.g. `Claude · 5h 1.2M tok ·
/// 7d 8.4M tok    Codex · 5h 3% · 7d 6%`. Hidden ENTIRELY when
/// `model.usageTiles` is empty — no placeholder, no "usage unavailable"
/// text — matching the spec's "hidden entirely otherwise". A monospaced
/// font gives tabular numerals so the tile values do not jitter as they
/// refresh.
struct CompanionUsageStripView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if !model.usageTiles.isEmpty {
            Text(summary)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(theme.palette.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, RafuMetrics.space3)
                .padding(.top, RafuMetrics.space2)
                .accessibilityLabel(summary)
        }
    }

    private var summary: String {
        model.usageTiles.map(Self.tileSummary).joined(separator: "    ")
    }

    private static func tileSummary(_ tile: AgentUsageTile) -> String {
        "\(tile.agent) · " + tile.windows.map(windowSummary).joined(separator: " · ")
    }

    private static func windowSummary(_ window: AgentUsageWindow) -> String {
        if let percent = window.percent {
            return "\(window.label) \(Int(percent.rounded()))%"
        }
        if let tokens = window.tokens {
            return "\(window.label) \(AgentUsageFormat.compactTokenCount(tokens)) tok"
        }
        return window.label
    }
}

/// The peek panel's editors list (terminal-notch-hud.md, "Peek", item 2) —
/// one card per open workspace window. Shown only while `hoverState !=
/// .resting`; empty-state text fills the same space per AGENTS' panel/tab
/// top-alignment rule so a single-row (or zero-row) list never floats the
/// whole strip toward the screen's vertical middle.
struct CompanionEditorsListView: View {
    let model: NotchCompanionModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Group {
            if model.editorRows.isEmpty {
                Text("No open editors")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.palette.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: RafuMetrics.space2) {
                    ForEach(model.editorRows) { row in
                        CompanionEditorRowView(row: row) {
                            model.focusEditor(row.id)
                        }
                    }
                }
                .padding(RafuMetrics.space3)
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
    }
}

/// One editor window's row: name + window number, the git one-liner (hidden
/// when no repository is open), and terminal chips — each chip shown only
/// when its count is non-zero (terminal-notch-hud.md, "Peek", item 2).
private struct CompanionEditorRowView: View {
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
/// empty — unlike `CompanionEditorsListView`, the feed has no empty state to
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
private struct CompanionFeedCardView: View {
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
