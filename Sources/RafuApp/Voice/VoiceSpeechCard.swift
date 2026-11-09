import RafuCore
import SwiftUI

/// The companion's one speech card (voice-presence.md): live captions, the
/// state's own words, a spoken agent update, the inline Confirm, or an
/// error. What shows comes from `VoiceCardPolicy`; the card hides 4 s after
/// the last change, except while Rafu speaks, a Confirm waits, an error
/// shows, or the pointer is over it. Colours come from the theme: the card
/// surface with ink tokens, solid under Reduce Transparency, and a strong
/// hairline under Increase Contrast.
struct VoiceSpeechCard: View {
    let session: VoiceSession
    /// Shows an agent's card on the board.
    let reveal: (VoiceAgentLine) -> Void
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.rafuMotionAllowed) private var motionAllowed
    @State private var hiddenContent: VoiceCardPolicy.Content?
    @State private var hovering = false
    @State private var announced: VoiceCardPolicy.Content?

    private var content: VoiceCardPolicy.Content {
        VoiceCardPolicy.content(
            VoiceCardPolicy.Inputs(
                state: session.blobState, caption: session.liveCaption,
                agentLine: session.agentLine, hint: session.hint,
                hasPendingConfirm: session.pendingConfirm != nil))
    }

    private var staysVisible: Bool {
        VoiceCardPolicy.staysVisible(content, state: session.blobState, hovering: hovering)
    }

    private var isShown: Bool {
        content != .none && (staysVisible || hiddenContent != content)
    }

    var body: some View {
        let content = content
        ZStack {
            if isShown {
                VoiceSpeechCardBody(
                    content: content, session: session, reveal: reveal,
                    busy: session.blobState == .thinking,
                    spins: motionAllowed && !reduceMotion
                )
                .id(content.swapKey)
                .transition(.opacity)
            }
        }
        .animation(
            RafuMotion.resolve(
                RafuMotion.cardSwap, reduceMotion: reduceMotion, reduced: RafuMotion.reducedFade),
            value: content.swapKey
        )
        .animation(
            RafuMotion.resolve(
                RafuMotion.cardShow, reduceMotion: reduceMotion, reduced: RafuMotion.reducedFade),
            value: isShown
        )
        .onHover { hovering = $0 }
        .task(id: HideKey(content: content, staysVisible: staysVisible)) {
            await hideLater(content)
        }
        .onChange(of: content) { _, next in announce(next) }
    }

    private struct HideKey: Equatable {
        let content: VoiceCardPolicy.Content
        let staysVisible: Bool
    }

    /// One sleep per change of content; nothing runs while the card is
    /// hidden or held open.
    private func hideLater(_ shown: VoiceCardPolicy.Content) async {
        guard shown != .none, !staysVisible else { return }
        do {
            try await Task.sleep(for: VoiceCardPolicy.hideAfter)
        } catch {
            return
        }
        guard !staysVisible else { return }
        hiddenContent = shown
    }

    /// The card is a live region: a caption is read at a sentence end, a
    /// Confirm and an error at once, an agent line when it arrives.
    private func announce(_ next: VoiceCardPolicy.Content) {
        guard next != announced else { return }
        let text: String?
        switch next {
        case .confirm:
            text = session.pendingConfirm.map { "Rafu needs your confirmation: \($0.title)" }
        case .error(let reason):
            text = "Rafu voice stopped: \(reason)"
        case .agent(let line):
            text = line.text
        case .caption(let speaker, let words):
            guard session.liveCaption?.endsSentence == true else { return }
            text = speaker == .you ? "You: \(words)" : words
        case .status, .none:
            text = nil
        }
        announced = next
        guard let text else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}

extension VoiceCardPolicy.Content {
    /// Changes when the card should cross-fade: a new kind or a new agent
    /// update. Caption words that grow do not cross-fade.
    fileprivate var swapKey: String {
        switch self {
        case .none: "none"
        case .status(let text): "status:\(text)"
        case .caption(let speaker, _): "caption:\(speaker)"
        case .agent(let line): "agent:\(line.sequence)"
        case .confirm: "confirm"
        case .error: "error"
        }
    }
}

/// The card's surface and one line of content.
private struct VoiceSpeechCardBody: View {
    let content: VoiceCardPolicy.Content
    let session: VoiceSession
    let reveal: (VoiceAgentLine) -> Void
    let busy: Bool
    let spins: Bool
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            row
        }
        .font(.callout)
        .foregroundStyle(theme.palette.textPrimary)
        .lineLimit(3)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    contrast == .increased
                        ? theme.palette.borderStrong : theme.palette.borderSubtle,
                    lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if busy { busyBadge }
        }
        .frame(maxWidth: VoiceCompanionPlacement.cardMaxWidth)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rafu voice card")
    }

    @ViewBuilder
    private var row: some View {
        switch content {
        case .none:
            EmptyView()
        case .status(let text):
            Text(text).foregroundStyle(theme.palette.textSecondary)
        case .caption(let speaker, let words):
            if speaker == .you {
                Text("\(Text("You: ").foregroundStyle(theme.palette.textSecondary))\(words)")
            } else {
                Text(words)
            }
        case .agent(let line):
            VoiceAgentLineRow(line: line, reveal: reveal)
        case .confirm:
            if let request = session.pendingConfirm {
                VoiceInlineConfirm(request: request, session: session)
            }
        case .error(let reason):
            Label {
                Text(reason)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.palette.warning)
            }
        }
    }

    /// "Working…": the delegation's progress chip and a small spinner.
    private var busyBadge: some View {
        HStack(spacing: 4) {
            if let chip = session.turnProgress.chip {
                Text(chip)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(theme.palette.textSecondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(theme.palette.chipBackground, in: Capsule())
                    .accessibilityLabel("\(chip) steps done")
            }
            if spins {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .accessibilityHidden(true)
            }
        }
        .padding(4)
        .offset(y: -14)
    }
}

/// The CLI glyph, one line, and a chevron that shows the card on the board.
private struct VoiceAgentLineRow: View {
    let line: VoiceAgentLine
    let reveal: (VoiceAgentLine) -> Void
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(line.monogram)
                .font(.caption2.weight(.bold))
                .foregroundStyle(theme.palette.onAccent)
                .frame(width: 16, height: 16)
                .background(theme.palette.accent, in: Circle())
                .accessibilityHidden(true)
            Text(line.text)
            Button {
                reveal(line)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            .buttonStyle(.plain)
            .help("Show \(line.title) on the board")
            .accessibilityLabel("Show \(line.title) on the board")
        }
    }
}

/// The Confirm card's question with ✓ and ✕. Both resolve the same gate as
/// the sheet; the gate answers once and closes the sheet.
private struct VoiceInlineConfirm: View {
    let request: VoiceConfirmRequest
    let session: VoiceSession
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(request.title).fontWeight(.semibold)
                if let first = request.summary.first {
                    Text(first)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 4)
            Button {
                session.answerConfirm(.allowOnce)
            } label: {
                Image(systemName: "checkmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(
                        request.isDestructive ? theme.palette.error : theme.palette.success
                    )
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(request.actionTitle)
            .accessibilityLabel(request.actionTitle)
            Button {
                session.answerConfirm(.cancel)
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(theme.palette.textSecondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .accessibilityLabel("Cancel")
        }
    }
}
