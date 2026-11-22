import RafuCore
import SwiftUI

/// The conversation column: the local overview, the stored questions and
/// answers, the question chips and the ask box.
struct MeetingConversationColumn: View {
    @Bindable var model: MeetingDetailModel
    /// The processing step of a meeting that is not ready, if any.
    let processingLabel: String?
    let onCite: (MeetingTurnID) -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: RafuMetrics.space3) {
                    if let overview = model.overview {
                        MeetingOverviewCard(overview: overview, model: model)
                    }
                    ForEach(model.conversation) { entry in
                        MeetingConversationEntryView(entry: entry, onCite: onCite)
                    }
                }
                .padding(RafuMetrics.space3)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            Divider()
            footer
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

    @ViewBuilder
    private var footer: some View {
        if !model.isReady {
            Label(
                processingLabel ?? "The text of this meeting is not ready yet.",
                systemImage: "hourglass"
            )
            .foregroundStyle(theme.palette.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if !model.hasRunner {
            Label("Questions are not in this build.", systemImage: "questionmark.bubble")
                .foregroundStyle(theme.palette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MeetingAskBox(model: model)
        }
    }
}

/// The ask box: chips, the question field, the agent menu, Send, the running
/// row with Cancel, and the error row.
private struct MeetingAskBox: View {
    @Bindable var model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme
    @FocusState private var fieldFocused: Bool

    private var trimmedDraft: String { MeetingDetailPresentation.cleanedQuestion(model.draft) }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            HStack(spacing: RafuMetrics.space1) {
                ForEach(MeetingDetailPresentation.chips) { chip in
                    Button(chip.title) { model.requestAsk(chip.question) }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .disabled(model.askState.isRunning)
                        .help(chip.question)
                }
            }
            switch model.askState {
            case .running(let cli):
                HStack(spacing: RafuMetrics.space2) {
                    ProgressView().controlSize(.small)
                    Text(MeetingDetailPresentation.runningText(cli: cli))
                        .foregroundStyle(theme.palette.textSecondary)
                    Spacer()
                    Button("Cancel") { model.cancelAsk() }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .keyboardShortcut(.cancelAction)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(theme.palette.error)
                    .textSelection(.enabled)
            case .idle:
                EmptyView()
            }
            HStack(alignment: .bottom, spacing: RafuMetrics.space2) {
                TextField("Ask about this meeting", text: $model.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($fieldFocused)
                    .onSubmit { send() }
                    .onChange(of: model.draft) { _, newValue in
                        if newValue.count > MeetingDetailPresentation.maximumQuestionLength {
                            model.draft = String(
                                newValue.prefix(MeetingDetailPresentation.maximumQuestionLength))
                        }
                    }
                    .accessibilityLabel("Question")
                MeetingAgentPicker(model: model)
                Button("Send") { send() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .disabled(trimmedDraft.isEmpty || model.askState.isRunning)
                    .help("Send the question to \(model.agent.displayName)")
            }
        }
    }

    private func send() {
        guard !trimmedDraft.isEmpty else { return }
        model.requestAsk(model.draft)
    }
}

/// The agent menu: Claude Code and Codex, each with its state.
struct MeetingAgentPicker: View {
    @Bindable var model: MeetingDetailModel

    var body: some View {
        Picker("Agent", selection: $model.agent) {
            ForEach(MeetingAgentCLI.allCases, id: \.self) { cli in
                Text(label(for: cli)).tag(cli)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .help("The agent that answers. It uses your own login.")
        .accessibilityLabel("Agent")
    }

    private func label(for cli: MeetingAgentCLI) -> String {
        guard
            let state = MeetingDetailPresentation.availabilityText(
                model.agentAvailability[cli], cli: cli)
        else { return cli.displayName }
        return "\(cli.displayName) — \(state)"
    }
}

/// The local overview card: made on this Mac, with no AI.
private struct MeetingOverviewCard: View {
    let overview: MeetingOverview
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space2) {
            Text("Overview")
                .font(.headline)
                .foregroundStyle(theme.palette.textPrimary)
            Text("Made on this Mac, with no AI.")
                .font(.caption)
                .foregroundStyle(theme.palette.textMuted)
            Text(
                "\(MeetingDetailPresentation.dateLine(startDate: overview.startDate, duration: overview.duration)) · \(overview.turnCount) turns"
            )
            .font(.callout)
            .foregroundStyle(theme.palette.textSecondary)
            ForEach(overview.speakers) { speaker in
                HStack(spacing: RafuMetrics.space2) {
                    Text(
                        MeetingDetailPresentation.shape(
                            for: speaker.label, in: overview.speakerLabels)
                    )
                    .accessibilityHidden(true)
                    Text(model.displayName(for: speaker.label))
                        .foregroundStyle(theme.palette.textPrimary)
                    Spacer()
                    Text(
                        "\(MeetingDetailPresentation.lengthText(speaker.talkSeconds)) · \(Int((MeetingDetailPresentation.talkShare(speaker, in: overview) * 100).rounded()))%"
                    )
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.textSecondary)
                }
                .font(.callout)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(RafuMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.cardBackground, in: .rect(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8).strokeBorder(theme.palette.borderSubtle))
    }
}

/// One stored question or answer. Answer text is model data: it is shown as
/// plain text; only a verified citation is a link.
private struct MeetingConversationEntryView: View {
    let entry: MeetingConversationEntry
    let onCite: (MeetingTurnID) -> Void

    @Environment(\.rafuTheme) private var theme

    private static let turnScheme = "rafu-meeting-turn"

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Text(author)
                .font(.caption.weight(.semibold))
                .foregroundStyle(theme.palette.textSecondary)
            switch entry.role {
            case .question:
                Text(entry.text)
                    .foregroundStyle(theme.palette.textPrimary)
                    .textSelection(.enabled)
            case .answer:
                answer
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var author: String {
        switch entry.role {
        case .question: "You"
        case .answer: entry.cli?.displayName ?? "Agent"
        }
    }

    @ViewBuilder
    private var answer: some View {
        let segments = MeetingDetailPresentation.answerSegments(
            text: entry.text, verified: Set(entry.citations.map(\.turn)))
        let marks = MeetingDetailPresentation.citationMarks(in: segments)
        Text(attributed(segments))
            .foregroundStyle(theme.palette.textPrimary)
            .textSelection(.enabled)
            .environment(
                \.openURL,
                OpenURLAction { url in
                    guard url.scheme == Self.turnScheme,
                        let turn = MeetingTurnID(
                            text: url.absoluteString.replacingOccurrences(
                                of: "\(Self.turnScheme):", with: ""))
                    else { return .discarded }
                    onCite(turn)
                    return .handled
                })
        if !marks.isEmpty {
            HStack(spacing: RafuMetrics.space1) {
                Text("Sources:")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                ForEach(marks) { mark in
                    if mark.isVerified {
                        Button(mark.turn.text) { onCite(mark.turn) }
                            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                            .help("Show turn \(mark.turn.text) in the transcript")
                            .accessibilityLabel("Show turn \(mark.turn.text)")
                    } else {
                        Text("\(mark.turn.text) · No source")
                            .font(.caption)
                            .foregroundStyle(theme.palette.textMuted)
                    }
                }
            }
        }
    }

    private func attributed(_ segments: [MeetingAnswerSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            switch segment {
            case .text(let text):
                result += AttributedString(text)
            case .citation(let turn, let verified):
                if verified {
                    var mark = AttributedString("[\(turn.text)]")
                    mark.link = URL(string: "\(Self.turnScheme):\(turn.text)")
                    result += mark
                } else {
                    var mark = AttributedString("[\(turn.text) · No source]")
                    mark.foregroundColor = theme.palette.textMuted
                    result += mark
                }
            }
        }
        return result
    }
}
