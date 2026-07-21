import SwiftUI

/// The notch HUD's content (terminal-notch-hud.md N-4): a compact pill
/// hanging under the notch, expanding in place to the full bounded snippet
/// plus the reply row. PRESENTATION ONLY — everything shown here arrives in
/// the `NotchHUDEvent` the controller was handed; this view never touches a
/// terminal, a buffer, or a pty. The theme arrives by value from the
/// controller (captured at show time) — the HUD belongs to no scene, so it
/// is injected into the environment manually for the shared control styles.
struct NotchHUDView: View {
    @Bindable var controller: NotchHUDController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var replyFocused: Bool

    private var theme: RafuTheme { controller.theme }

    var body: some View {
        Group {
            if let event = controller.event {
                switch controller.state {
                case .compact:
                    compactContent(event)
                        .transition(transition)
                case .expanded:
                    expandedContent(event)
                        .transition(transition)
                }
            }
        }
        .padding(.top, controller.bandInset)
        .frame(width: NotchHUDController.layoutWidth, height: height)
        .background(hudShape.fill(surfaceColor))
        .overlay(hudShape.strokeBorder(borderColor, lineWidth: borderWidth))
        .clipShape(hudShape)
        .onHover { controller.isHovered = $0 }
        .onKeyPress(.escape) {
            controller.escapePressed()
            return .handled
        }
        .onChange(of: replyFocused) { _, focused in
            if focused {
                controller.engageReply()
            } else {
                controller.disengageReply()
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .easeOut(duration: 0.18),
            value: controller.state
        )
        .environment(\.rafuTheme, theme)
    }

    private var height: CGFloat {
        (controller.state == .compact
            ? NotchHUDController.compactHeight : NotchHUDController.expandedHeight)
            + controller.bandInset
    }

    /// On a notched screen the surface is TRUE BLACK so the band region
    /// merges with the physical housing — that is what "seamless" means
    /// here; any gray reads as a floating card. The non-notch fallback
    /// keeps the themed elevated surface, since there is no housing to
    /// blend with under a regular menu bar.
    private var surfaceColor: Color {
        controller.bandInset > 0 ? Color.black : theme.palette.elevatedBackground
    }

    /// Bottom-rounded so the HUD reads as attached to the notch / menu bar
    /// its top edge is flush with.
    private var hudShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: RafuMetrics.radiusPanel,
            bottomTrailingRadius: RafuMetrics.radiusPanel,
            topTrailingRadius: 0,
            style: .continuous
        )
    }

    /// The session color IS the border, matching the Terminals panel cards;
    /// Increase Contrast always gets a defined border (product decision 6).
    private var borderColor: Color {
        if let color = controller.event?.color {
            return theme.palette.color(for: color)
        }
        return contrast == .increased
            ? theme.palette.borderStrong
            : theme.palette.borderSubtle.opacity(0.6)
    }

    private var borderWidth: CGFloat {
        controller.event?.color != nil ? 2 : RafuMetrics.hairline
    }

    /// Reduce Motion: cross-fade only, no slide (product decision 6).
    private var transition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top))
    }

    // MARK: - Compact

    /// The pill: status glyph, session name, first snippet line, and the
    /// "+N more" chip when sessions queued behind it. Clicking anywhere
    /// except the chip expands in place (the expanded state's name click is
    /// the reveal-and-dismiss path — product decision 5).
    @ViewBuilder
    private func compactContent(_ event: NotchHUDEvent) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: TerminalSessionPresentation.symbol(.bell))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
            Text(event.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if !firstSnippetLine(event).isEmpty {
                Text(firstSnippetLine(event))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(theme.palette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
            if controller.pendingCount > 0 {
                moreChip(count: controller.pendingCount)
            }
        }
        .padding(.horizontal, RafuMetrics.space3)
        .contentShape(Rectangle())
        .onTapGesture { controller.expand() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Terminal \(event.title) needs attention")
        .accessibilityHint("Activates to show the recent output and a reply field")
        .accessibilityAddTraits(.isButton)
    }

    private func firstSnippetLine(_ event: NotchHUDEvent) -> String {
        event.snippet.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            ?? ""
    }

    private func moreChip(count: Int) -> some View {
        Button {
            controller.revealQueueAndDismiss()
        } label: {
            Text("+\(count) more")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(theme.palette.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    Capsule(style: .continuous).fill(theme.palette.chipBackground)
                )
        }
        .buttonStyle(.plain)
        .help("Show all sessions that need attention in the Terminals panel")
        .accessibilityLabel("\(count) more sessions need attention")
        .accessibilityHint("Activates to open the Terminals panel")
    }

    // MARK: - Expanded

    @ViewBuilder
    private func expandedContent(_ event: NotchHUDEvent) -> some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            expandedHeader(event)
            snippetBlock(event)
            replyRow(event)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, RafuMetrics.space3)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func expandedHeader(_ event: NotchHUDEvent) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            Image(systemName: TerminalSessionPresentation.symbol(.bell))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(theme.palette.accent)
            // Clicking the session name reveals its tab and dismisses
            // (product decision 5).
            Button {
                controller.revealSessionAndDismiss()
            } label: {
                Text(event.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Reveal this terminal in its window")
            .accessibilityHint("Activates to reveal the terminal tab and dismiss the HUD")
            Spacer(minLength: 0)
            if controller.pendingCount > 0 {
                moreChip(count: controller.pendingCount)
            }
            Button("Dismiss", systemImage: "xmark") { controller.escapePressed() }
                .buttonStyle(RafuIconButtonStyle(size: 20, iconSize: 9))
                .help("Dismiss (Escape)")
        }
    }

    /// The full bounded snippet — at most the 6 lines/512 bytes the
    /// existing seam already produced; one line per row, never wrapped.
    private func snippetBlock(_ event: NotchHUDEvent) -> some View {
        let lines = event.snippet.split(separator: "\n", omittingEmptySubsequences: false)
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
                .fill(theme.palette.cardBackground)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Recent output")
    }

    private func replyRow(_ event: NotchHUDEvent) -> some View {
        HStack(spacing: RafuMetrics.space2) {
            TextField("Reply to \(event.title)…", text: $controller.replyText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($replyFocused)
                .onSubmit { controller.sendReply() }
                .padding(.horizontal, RafuMetrics.space2)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                        .fill(theme.palette.fieldBackground)
                )
                .accessibilityLabel("Reply to \(event.title)")
            Button("Send") { controller.sendReply() }
                .buttonStyle(RafuProminentButtonStyle(compact: true))
                .disabled(controller.replyText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send the reply to that terminal")
        }
    }
}
