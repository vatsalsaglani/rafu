import RafuCore
import SwiftUI

/// The Transcript sidebar: names to check, rename, name suggestions, the
/// turns (paged), the echo toggle, the engines and "Make the text again".
struct MeetingTranscriptSidebar: View {
    let model: MeetingDetailModel
    /// True while the meeting is processed (no "Make the text again").
    let isProcessing: Bool
    let onRemake: (MeetingTextEngineID) -> Void

    @Environment(\.rafuTheme) private var theme
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingLabel: MeetingSpeakerLabel?
    @State private var remakeRequest: MeetingRemakeRequest?

    private var nameLabels: [MeetingSpeakerLabel] {
        var labels = model.namesToCheck
        if let editingLabel, !labels.contains(editingLabel) { labels.insert(editingLabel, at: 0) }
        return labels
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: RafuMetrics.space2) {
                    namesSection
                    speakerModelHint
                    echoToggle
                    ForEach(model.shownTurns) { turn in
                        MeetingTurnRow(
                            turn: turn,
                            shape: MeetingDetailPresentation.shape(
                                for: turn.speaker, in: model.speakerOrder),
                            name: model.displayName(for: turn.speaker),
                            isHighlighted: model.highlightedTurn == turn.id,
                            onRename: { editingLabel = turn.speaker }
                        )
                        .id(turn.id)
                    }
                    if model.hasMoreTurns {
                        Button("Load more") { Task { await model.loadMoreTurns() } }
                            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                            .frame(maxWidth: .infinity)
                    }
                    if model.isReady, model.overview?.turnCount == 0 {
                        Text("This meeting has no text.")
                            .foregroundStyle(theme.palette.textSecondary)
                    }
                    enginesFooter
                }
                .padding(RafuMetrics.space2)
            }
            .onChange(of: model.revealRequest) {
                guard let turn = model.highlightedTurn else { return }
                if reduceMotion {
                    proxy.scrollTo(turn, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(turn, anchor: .center) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.revealRequest) {
            guard model.highlightedTurn != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            model.highlightedTurn = nil
        }
        .sheet(item: $remakeRequest) { request in
            RafuConfirmPopup(
                symbol: "arrow.triangle.2.circlepath",
                title: "Make the text again?",
                message: MeetingDetailPresentation.remakeConfirmation(request.engine),
                actions: [
                    .init("Make the Text Again", isDestructive: true) {
                        remakeRequest = nil
                        onRemake(request.engine)
                    }
                ]
            ) {
                remakeRequest = nil
            }
        }
    }

    // MARK: Names

    @ViewBuilder
    private var namesSection: some View {
        let toCheck = model.namesToCheck
        if !toCheck.isEmpty || editingLabel != nil || !model.suggestions.isEmpty {
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                if !toCheck.isEmpty {
                    HStack(spacing: RafuMetrics.space2) {
                        Label(
                            MeetingDetailPresentation.namesBanner(count: toCheck.count),
                            systemImage: "person.crop.circle.badge.questionmark"
                        )
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                        Spacer()
                        if model.canAsk {
                            Button("Suggest names") { model.requestNameSuggestions() }
                                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                                .disabled(model.suggestState.isRunning)
                                .help(
                                    "Ask \(model.agent.displayName) for names. Nothing changes until you accept a name."
                                )
                        }
                    }
                }
                suggestionState
                ForEach(model.suggestions, id: \.label) { suggestion in
                    MeetingSuggestionRow(suggestion: suggestion, model: model)
                }
                ForEach(nameLabels, id: \.self) { label in
                    MeetingSpeakerNameField(
                        label: label, current: model.names.name(for: label) ?? "",
                        onSave: { name in
                            Task {
                                if await model.rename(label, to: name), editingLabel == label {
                                    editingLabel = nil
                                }
                            }
                        },
                        onCancel: editingLabel == label ? { editingLabel = nil } : nil)
                }
                if let error = model.renameError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(theme.palette.error)
                }
            }
            .padding(RafuMetrics.space2)
            .background(theme.palette.cardBackground, in: .rect(cornerRadius: 8))
            Divider()
        }
    }

    @ViewBuilder
    private var suggestionState: some View {
        switch model.suggestState {
        case .running(let cli):
            HStack(spacing: RafuMetrics.space2) {
                ProgressView().controlSize(.small)
                Text(MeetingDetailPresentation.runningText(cli: cli))
                    .font(.callout)
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
                Button("Cancel") { model.cancelSuggestions() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(theme.palette.error)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var speakerModelHint: some View {
        if let overview = model.overview, !overview.hasNumberedSpeakers,
            model.summary?.engines.speakerEngine == nil, overview.turnCount > 0
        {
            HStack(spacing: RafuMetrics.space2) {
                Text("Tell speakers apart: download a speaker model in Settings ▸ Meetings")
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                Spacer()
                Button("Open Settings…") {
                    SettingsPaneRouter.shared.request(.meetings)
                    openSettings()
                }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
    }

    @ViewBuilder
    private var echoToggle: some View {
        if let count = model.overview?.echoCount, count > 0 {
            Button(MeetingDetailPresentation.echoToggleTitle(count: count, shown: model.showsEcho))
            {
                model.showsEcho.toggle()
            }
            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            .help("Echo lines are the call sound heard again through your microphone.")
        }
    }

    // MARK: Engines

    @ViewBuilder
    private var enginesFooter: some View {
        if let summary = model.summary, summary.engines.textEngine != nil {
            Divider()
            VStack(alignment: .leading, spacing: RafuMetrics.space1) {
                Text(MeetingDetailPresentation.engineLine(summary.engines))
                    .font(.caption)
                    .foregroundStyle(theme.palette.textMuted)
                let choices = MeetingDetailPresentation.remakeChoices(
                    used: summary.engines.textEngine, available: model.textEngineAvailability)
                if !choices.isEmpty, !isProcessing, model.isReady {
                    Menu("Make the text again with") {
                        ForEach(choices, id: \.self) { engine in
                            Button(MeetingDetailPresentation.textEngineName(engine)) {
                                remakeRequest = MeetingRemakeRequest(engine: engine)
                            }
                        }
                    }
                    .menuStyle(.button)
                    .fixedSize()
                    .help("Make the transcript again with another text engine.")
                }
            }
        }
    }
}

/// A "Make the text again" choice that waits for confirmation.
private struct MeetingRemakeRequest: Identifiable {
    let engine: MeetingTextEngineID
    var id: MeetingTextEngineID { engine }
}

/// One turn: a shape and the speaker name (a button that opens the rename
/// field), the time, the text.
private struct MeetingTurnRow: View {
    let turn: MeetingTurn
    let shape: String
    let name: String
    let isHighlighted: Bool
    let onRename: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: RafuMetrics.space1) {
                Button(action: onRename) {
                    Text("\(shape) \(name)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.palette.textPrimary)
                }
                .buttonStyle(.plain)
                .help("Rename \(name)")
                .accessibilityLabel("\(name). Rename")
                if turn.isEcho {
                    Text("echo")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textMuted)
                }
                Spacer()
                Text(MeetingClockText.text(turn.start))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(theme.palette.textMuted)
            }
            Text(turn.text)
                .font(.callout)
                .foregroundStyle(
                    turn.isEcho ? theme.palette.textSecondary : theme.palette.textPrimary
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(RafuMetrics.space1)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isHighlighted ? theme.palette.accent : .clear, lineWidth: 2)
        )
    }
}

/// A text field "Name for Speaker 2" with Save.
private struct MeetingSpeakerNameField: View {
    let label: MeetingSpeakerLabel
    let current: String
    let onSave: (String) -> Void
    let onCancel: (() -> Void)?

    @State private var text = ""

    var body: some View {
        let defaultName = MeetingSpeakerNames.defaultName(for: label)
        HStack(spacing: RafuMetrics.space1) {
            TextField("Name for \(defaultName)", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
                .onChange(of: text) { _, newValue in
                    if newValue.count > MeetingSpeakerNames.maximumNameLength {
                        text = String(newValue.prefix(MeetingSpeakerNames.maximumNameLength))
                    }
                }
                .accessibilityLabel("Name for \(defaultName)")
            Button("Save", action: save)
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                .disabled(text.trimmingCharacters(in: .whitespaces) == current)
            if let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .onAppear { text = current }
    }

    private func save() {
        onSave(text)
    }
}

/// "Speaker 2 → Priya" with Accept and Dismiss.
private struct MeetingSuggestionRow: View {
    let suggestion: MeetingSpeakerNameSuggestion
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space1) {
            Text("\(model.displayName(for: suggestion.label)) → \(suggestion.name)")
                .font(.callout)
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer()
            Button("Accept") { Task { await model.accept(suggestion) } }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            Button("Dismiss") { model.dismiss(suggestion) }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
    }
}
