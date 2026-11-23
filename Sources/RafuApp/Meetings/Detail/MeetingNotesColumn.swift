import RafuCore
import SwiftUI

/// The Notes column: the summary block, the speakers strip, and the
/// transcript under its pinned bar. The text column is at most 680 pt
/// wide and leading aligned.
struct MeetingNotesColumn: View {
    @Bindable var model: MeetingDetailModel
    let summary: MeetingSummaryContext
    /// Goes up when Command-F asks for the transcript search field.
    let searchFocusRequest: Int

    @Environment(\.rafuTheme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let textColumnWidth: CGFloat = 680

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    VStack(alignment: .leading, spacing: RafuMetrics.space4) {
                        MeetingSummaryBlock(model: model, context: summary)
                        MeetingSpeakerStrip(model: model)
                    }
                    .frame(maxWidth: Self.textColumnWidth, alignment: .leading)
                    .padding(.horizontal, RafuMetrics.space5)
                    .padding(.top, RafuMetrics.space5)
                    .padding(.bottom, RafuMetrics.space4)
                    Section {
                        MeetingTranscriptSection(model: model)
                            .frame(maxWidth: Self.textColumnWidth, alignment: .leading)
                            .padding(.horizontal, RafuMetrics.space5)
                            .padding(.bottom, RafuMetrics.space5)
                    } header: {
                        MeetingTranscriptBar(model: model, focusRequest: searchFocusRequest)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.revealRequest) { scrollToTarget(proxy) }
            .onAppear { scrollToTarget(proxy) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task(id: model.highlightedTurn) {
            guard model.highlightedTurn != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            model.highlightedTurn = nil
        }
    }

    /// Scrolls to the group of the turn that a citation or a search asked
    /// for. With Reduce Motion it jumps.
    private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let target = model.revealTarget,
            let group = model.groupID(containing: target)
        else { return }
        model.revealTarget = nil
        if reduceMotion {
            proxy.scrollTo(group, anchor: .center)
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(group, anchor: .center) }
        }
    }
}

/// What the summary block needs from the session: the state, the agent
/// that writes it, and the actions.
struct MeetingSummaryContext {
    var state: MeetingSummaryState
    var writingCLI: MeetingAgentCLI
    var make: () -> Void
    var cancel: () -> Void
}

// MARK: - Speakers

/// The speakers: a wrapped row of pills (shape, name, talk share) and
/// "Suggest names". A pill opens the rename popover. A speaker with no
/// name has a dashed border.
struct MeetingSpeakerStrip: View {
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        if let overview = model.overview, !overview.shownSpeakers.isEmpty {
            VStack(alignment: .leading, spacing: RafuMetrics.space2) {
                MeetingFlowLayout(spacing: RafuMetrics.space2) {
                    ForEach(overview.shownSpeakers) { speaker in
                        MeetingSpeakerPill(
                            model: model, speaker: speaker,
                            shape: MeetingDetailPresentation.shape(
                                for: speaker.speaker, in: overview.speakerLabels))
                    }
                    if model.canAsk, !model.namesToCheck.isEmpty {
                        Button {
                            model.requestNameSuggestions()
                        } label: {
                            Label(
                                "Suggest names",
                                systemImage: "person.crop.circle.badge.questionmark")
                        }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        .disabled(model.suggestState.isRunning)
                        .help(
                            "Ask \(model.agent.displayName) for names. Nothing changes until you accept a name."
                        )
                    }
                }
                suggestionState
                ForEach(model.suggestions, id: \.label) { suggestion in
                    MeetingNameSuggestionRow(suggestion: suggestion, model: model)
                }
                if let error = model.renameError {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.palette.textPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var suggestionState: some View {
        switch model.suggestState {
        case .running(let cli):
            HStack(spacing: RafuMetrics.space2) {
                ProgressView().controlSize(.small)
                Text(MeetingDetailPresentation.runningText(cli: cli))
                    .foregroundStyle(theme.palette.textSecondary)
                Button("Cancel") { model.cancelSuggestions() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
            .font(.system(size: 12))
        case .failed(let message):
            Label {
                Text(message).foregroundStyle(theme.palette.textPrimary)
            } icon: {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.palette.warning)
            }
            .font(.system(size: 12))
        case .busy:
            Text(MeetingAgentError.busy.message)
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textSecondary)
        case .idle:
            if case .noNamesFound(let cli) = model.suggestOutcome {
                HStack(spacing: RafuMetrics.space2) {
                    Text(MeetingDetailPresentation.noNamesText(cli: cli))
                        .foregroundStyle(theme.palette.textSecondary)
                    Button("Dismiss") { model.dismissSuggestOutcome() }
                        .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                }
                .font(.system(size: 12))
            }
        }
    }

}

/// One speaker pill: "◆ Shilpa 57%". It opens the rename popover.
private struct MeetingSpeakerPill: View {
    let model: MeetingDetailModel
    let speaker: MeetingSpeakerStats
    let shape: String

    @Environment(\.rafuTheme) private var theme
    @State private var isRenaming = false

    private var name: String { model.displayName(for: speaker.speaker) }
    private var isUnnamed: Bool {
        speaker.speaker != .me && model.names.name(for: speaker.speaker) == nil
    }

    var body: some View {
        Button {
            isRenaming = true
        } label: {
            HStack(spacing: RafuMetrics.space1) {
                Text(shape).accessibilityHidden(true)
                Text(name)
                    .foregroundStyle(theme.palette.textPrimary)
                    .lineLimit(1)
                Text(MeetingDetailPresentation.shareText(speaker.share))
                    .monospacedDigit()
                    .foregroundStyle(theme.palette.textMuted)
            }
            .font(.system(size: 12))
            .padding(.horizontal, RafuMetrics.space2)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.palette.chipBackground))
            .overlay(
                Capsule().strokeBorder(
                    isUnnamed ? theme.palette.textMuted : theme.palette.borderSubtle,
                    style: StrokeStyle(lineWidth: 1, dash: isUnnamed ? [3, 2] : []))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Rename \(name)")
        .accessibilityLabel(
            MeetingDetailPresentation.speakerAccessibilityLabel(name: name, share: speaker.share)
        )
        .popover(isPresented: $isRenaming, arrowEdge: .bottom) {
            MeetingSpeakerRenamePopover(model: model, label: speaker.speaker) {
                isRenaming = false
            }
        }
    }
}

/// The rename popover: "Name for Speaker 1", Save and Cancel. An empty
/// name clears the name.
struct MeetingSpeakerRenamePopover: View {
    let model: MeetingDetailModel
    let label: MeetingSpeakerLabel
    let onClose: () -> Void

    @Environment(\.rafuTheme) private var theme
    @State private var text = ""
    @State private var isSaving = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        let defaultName = MeetingSpeakerNames.defaultName(for: label)
        VStack(alignment: .leading, spacing: RafuMetrics.space3) {
            Text("Name for \(defaultName)")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.textPrimary)
            TextField("Name", text: $text)
                .textFieldStyle(.plain)
                .rafuField(isFocused: fieldFocused)
                .focused($fieldFocused)
                .onSubmit(save)
                .onChange(of: text) { _, newValue in
                    if newValue.count > MeetingSpeakerNames.maximumNameLength {
                        text = String(newValue.prefix(MeetingSpeakerNames.maximumNameLength))
                    }
                }
                .accessibilityLabel("Name for \(defaultName)")
            if let error = model.renameError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(theme.palette.textSecondary)
            }
            HStack(spacing: RafuMetrics.space2) {
                Spacer()
                Button("Cancel", action: onClose)
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .buttonStyle(RafuProminentButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
        }
        .padding(RafuMetrics.space4)
        .frame(width: 280)
        .onAppear {
            text = model.names.name(for: label) ?? ""
            fieldFocused = true
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            let saved = await model.rename(label, to: text)
            isSaving = false
            if saved { onClose() }
        }
    }
}

/// "Speaker 1 → Priya" with Accept and Dismiss.
struct MeetingNameSuggestionRow: View {
    let suggestion: MeetingSpeakerNameSuggestion
    let model: MeetingDetailModel

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        HStack(spacing: RafuMetrics.space2) {
            Text("\(model.displayName(for: suggestion.label)) → \(suggestion.name)")
                .font(.system(size: 12))
                .foregroundStyle(theme.palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: RafuMetrics.space2)
            Button("Accept") { Task { await model.accept(suggestion) } }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            Button("Dismiss") { model.dismiss(suggestion) }
                .buttonStyle(RafuSecondaryButtonStyle(compact: true))
        }
        .accessibilityElement(children: .contain)
    }
}
