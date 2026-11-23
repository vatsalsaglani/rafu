import RafuCore
import SwiftUI

/// The Ask column: the stored questions and answers (or the empty state
/// with suggestions), the question that waits, the streamed answer, and
/// the composer. Answer text is model data: it shows through
/// `MeetingAnswerMarkdown`, and only a verified citation is a link.
struct MeetingAskColumn: View {
    @Bindable var model: MeetingDetailModel
    /// True while a question run of this meeting goes on in another view.
    let isRunningElsewhere: Bool
    let onCite: (MeetingTurnID) -> Void

    private var isEmpty: Bool {
        model.conversation.isEmpty && model.pendingQuestion == nil
            && model.askState == .idle
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isEmpty {
                MeetingAskEmptyState(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MeetingAskThread(model: model, onCite: onCite)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            MeetingAskComposer(model: model, isRunningElsewhere: isRunningElsewhere)
                .padding(RafuMetrics.space3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $model.pendingConsent) { action in
            RafuConfirmPopup(
                symbol: "paperplane",
                title: MeetingDetailPresentation.consentTitle(cli: action.cli),
                message: MeetingDetailPresentation.consentText(cli: action.cli),
                actions: [.init("Send") { model.confirmConsent() }]
            ) {
                model.declineConsent()
            }
        }
    }
}

/// The empty Ask column: a symbol, "Ask about this meeting", and three
/// suggestion buttons.
struct MeetingAskEmptyState: View {
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: RafuMetrics.space3) {
            Image(systemName: "sparkles")
                .font(.system(size: 20))
                .foregroundStyle(theme.palette.textMuted)
                .accessibilityHidden(true)
            Text("Ask about this meeting")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            if model.canAsk {
                VStack(spacing: RafuMetrics.space2) {
                    ForEach(MeetingDetailPresentation.questionSuggestions) { suggestion in
                        Button(suggestion.title) { model.requestAsk(suggestion.question) }
                            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                            .help(suggestion.question)
                    }
                }
            }
        }
        .padding(RafuMetrics.space5)
    }
}

/// The thread: each stored line, the divider after the lines for an older
/// text, the question that waits, the answer that streams, and the error
/// or busy row. It follows the newest line unless the user scrolled up.
struct MeetingAskThread: View {
    let model: MeetingDetailModel
    let onCite: (MeetingTurnID) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var followsNewest = true

    private static let bottomID = "meeting-ask-bottom"

    private struct FollowKey: Equatable {
        var count: Int
        var pending: Bool
        var streamed: Int
        var state: MeetingAskState
    }

    var body: some View {
        let staleAfter = MeetingDetailPresentation.staleDividerAfter(
            model.conversation, currentRevision: model.textRevision)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RafuMetrics.space4) {
                    ForEach(model.conversation) { entry in
                        MeetingConversationEntryView(
                            entry: entry, model: model,
                            isStale: MeetingDetailPresentation.isStale(
                                entry, currentRevision: model.textRevision),
                            onCite: onCite)
                        if entry.id == staleAfter {
                            MeetingStaleDivider()
                        }
                    }
                    MeetingPendingRun(model: model)
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(RafuMetrics.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height
                    >= geometry.contentSize.height - 24
            } action: { _, atBottom in
                followsNewest = atBottom
            }
            .onChange(
                of: FollowKey(
                    count: model.conversation.count, pending: model.pendingQuestion != nil,
                    streamed: model.streamingText.count, state: model.askState)
            ) {
                guard followsNewest else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onAppear { proxy.scrollTo(Self.bottomID, anchor: .bottom) }
        }
    }
}

/// One stored question (a bubble) or answer (Markdown with chips).
private struct MeetingConversationEntryView: View {
    let entry: MeetingConversationEntry
    let model: MeetingDetailModel
    let isStale: Bool
    let onCite: (MeetingTurnID) -> Void

    var body: some View {
        switch entry.role {
        case .question:
            MeetingQuestionBubble(text: entry.text)
        case .answer:
            let verified = Set(entry.citations.map(\.turn))
            MeetingAnswerView(
                meta: MeetingDetailPresentation.agentMeta(cli: entry.cli, date: entry.date),
                markdown: MeetingDetailPresentation.answerMarkdown(
                    entry.text, verified: verified, refs: model.turnRefs, names: model.names),
                chips: MeetingDetailPresentation.citationChips(
                    in: entry.text, verified: verified, refs: model.turnRefs, names: model.names
                ),
                chipsActive: !isStale,
                onCite: onCite)
        }
    }
}

/// The question that was sent, the answering row or the streamed text,
/// and the error or busy row.
private struct MeetingPendingRun: View {
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if let pending = model.pendingQuestion {
            MeetingQuestionBubble(text: pending.text)
            if model.askState.isRunning {
                if model.streamingText.isEmpty {
                    HStack(spacing: RafuMetrics.space2) {
                        ProgressView().controlSize(.small)
                        Text(MeetingDetailPresentation.runningText(cli: pending.cli))
                            .font(.system(size: 12))
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    MeetingAnswerView(
                        meta: pending.cli.displayName,
                        markdown: MeetingDetailPresentation.streamingMarkdown(
                            model.streamingText),
                        chips: [], chipsActive: false, onCite: { _ in })
                }
            }
        }
        switch model.askState {
        case .failed(let message):
            MeetingAskErrorRow(message: message) { model.retryFailedQuestion() }
        case .busy:
            Label(MeetingAgentError.busy.message, systemImage: "hourglass")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
        case .idle, .running:
            EmptyView()
        }
    }
}

/// A question: right, on the soft accent, at most 80 percent wide.
struct MeetingQuestionBubble: View {
    let text: String

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(theme.palette.textPrimary)
            .textSelection(.enabled)
            .padding(.horizontal, RafuMetrics.space3)
            .padding(.vertical, RafuMetrics.space2)
            .background(
                theme.palette.accentSoft,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .frame(maxWidth: .infinity, alignment: .trailing)
            .containerRelativeFrame(.horizontal, alignment: .trailing) { length, _ in
                length * 0.8
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("You: \(text)")
    }
}

/// An answer: left, with no bubble; the agent and time, the Markdown, and
/// the citation chips.
struct MeetingAnswerView: View {
    let meta: String
    let markdown: String
    let chips: [MeetingCitationChip]
    let chipsActive: Bool
    let onCite: (MeetingTurnID) -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Text(meta)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(theme.palette.textMuted)
            MeetingAnswerMarkdown(markdown: markdown, onCite: onCite)
            if !chips.isEmpty {
                MeetingCitationChips(chips: chips, isActive: chipsActive, onCite: onCite)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The citation chips: "02:13 Shilpa". A chip loads the page, scrolls the
/// transcript and marks the line. Chips of an answer for an older text are
/// inactive.
struct MeetingCitationChips: View {
    let chips: [MeetingCitationChip]
    let isActive: Bool
    let onCite: (MeetingTurnID) -> Void

    var body: some View {
        MeetingFlowLayout(spacing: RafuMetrics.space1) {
            ForEach(chips) { chip in
                Button(chip.label) { onCite(chip.turn) }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .font(.system(size: 11).monospacedDigit())
                    .disabled(!isActive)
                    .help(isActive ? chip.accessibilityLabel : "This line is from an older text.")
                    .accessibilityLabel(chip.accessibilityLabel)
            }
        }
    }
}

/// "The text was made again. Earlier answers point to the old text."
private struct MeetingStaleDivider: View {
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Rectangle().fill(theme.palette.borderSubtle).frame(height: 1)
            Text(MeetingDetailPresentation.staleDividerText)
                .font(.system(size: 11))
                .foregroundStyle(theme.palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .multilineTextAlignment(.center)
            Rectangle().fill(theme.palette.borderSubtle).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The error under a question, with "Try Again".
private struct MeetingAskErrorRow: View {
    let message: String
    let onRetry: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: RafuMetrics.space2) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(theme.palette.warning)
                .accessibilityHidden(true)
            Text(message)
                .foregroundStyle(theme.palette.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Try Again", action: onRetry)
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .help("Put the question back in the field")
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .contain)
    }
}

/// The composer card: the question field (1 to 6 lines), the agent menu
/// and the round Send or Stop button. Return sends; Shift-Return makes a
/// new line; Escape stops a run.
struct MeetingAskComposer: View {
    @Bindable var model: MeetingDetailModel
    let isRunningElsewhere: Bool

    @Environment(\.rafuTheme) private var theme
    @FocusState private var fieldFocused: Bool

    private var isRunning: Bool { model.askState.isRunning || isRunningElsewhere }
    private var canSend: Bool {
        model.canAsk && !isRunning
            && !MeetingDetailPresentation.cleanedQuestion(model.draft).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            if model.hasRunner, model.hasNoReadyAgent {
                Text(MeetingDetailPresentation.noAgentText)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Ask about this meeting", text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .focused($fieldFocused)
                .disabled(!model.canAsk)
                .onSubmit(send)
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.shift) else { return .ignored }
                    model.draft += "\n"
                    return .handled
                }
                .onChange(of: model.draft) { _, newValue in
                    if newValue.count > MeetingDetailPresentation.maximumQuestionLength {
                        model.draft = String(
                            newValue.prefix(MeetingDetailPresentation.maximumQuestionLength))
                    }
                }
                .accessibilityLabel("Question")
            HStack(spacing: RafuMetrics.space2) {
                if model.hasRunner {
                    MeetingAgentMenu(model: model)
                }
                Spacer(minLength: 0)
                sendOrStop
            }
        }
        .padding(RafuMetrics.space2)
        .background(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                .fill(theme.palette.fieldBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: RafuMetrics.radiusField, style: .continuous)
                .strokeBorder(
                    fieldFocused ? theme.palette.focusRing : theme.palette.borderSubtle,
                    lineWidth: RafuMetrics.hairline)
        )
        .opacity(model.canAsk || isRunning ? 1 : 0.6)
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if isRunning {
            MeetingRoundButton(symbol: "stop.fill", isEnabled: true) { stop() }
                .keyboardShortcut(.cancelAction)
                .help("Stop the answer (Escape)")
                .accessibilityLabel("Stop")
        } else {
            MeetingRoundButton(symbol: "arrow.up", isEnabled: canSend) { send() }
                .disabled(!canSend)
                .help("Send the question to \(model.agent.displayName) (Return)")
                .accessibilityLabel("Send")
        }
    }

    private func send() {
        guard canSend else { return }
        model.requestAsk(model.draft)
    }

    private func stop() {
        if model.askState.isRunning {
            model.cancelAsk()
        } else {
            Task { await model.stopOtherRun() }
        }
    }
}

/// A 24 pt round button with one symbol.
private struct MeetingRoundButton: View {
    let symbol: String
    let isEnabled: Bool
    let action: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isEnabled ? theme.palette.onAccent : theme.palette.textMuted)
                .frame(width: 24, height: 24)
                .background(
                    Circle().fill(isEnabled ? theme.palette.accent : theme.palette.chipBackground)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// The small agent menu, "Claude Code ▾": each agent that passed the
/// probe, and each other agent inactive with its reason.
struct MeetingAgentMenu: View {
    @Bindable var model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Menu {
            ForEach(MeetingAgentCLI.allCases, id: \.self) { cli in
                let result = model.probeResults[cli]
                Button {
                    model.agent = cli
                } label: {
                    if cli == model.agent {
                        Label(
                            MeetingDetailPresentation.agentMenuTitle(cli: cli, result: result),
                            systemImage: "checkmark")
                    } else {
                        Text(MeetingDetailPresentation.agentMenuTitle(cli: cli, result: result))
                    }
                }
                .disabled(result.map { !$0.isReady } ?? false)
            }
        } label: {
            HStack(spacing: 3) {
                Text(model.agent.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: 130, alignment: .leading)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The agent that answers. It uses your own login.")
        .accessibilityLabel("Agent: \(model.agent.displayName)")
    }
}
