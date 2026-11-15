import SwiftUI

/// The Source Control commit composer (G7, Option B): a summary line and a
/// description in one field, and one full-width button that names the next
/// step ("Stage All 3 Files", "Commit 2 Files to main", "Drafting…").
///
/// The composer paints no surface of its own. One hairline at its top
/// separates it from the list that scrolls behind it; in Solid the sidebar
/// token shows through, in Frosted the window backdrop does (ADR 0038). The
/// field keeps the opaque `rafuField` chrome, the same as the Search field.
///
/// The model keeps ONE message string. The two parts read and write it
/// through `GitCommitMessageParts`. While an AI draft streams, the draft
/// owns the whole message: each delta replaces it. Stop keeps what arrived.
struct GitCommitComposerView: View {
    @Environment(\.rafuTheme) private var theme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.openSettings) private var openSettings
    @Bindable var session: WorkspaceSession

    private enum Part: Hashable {
        case summary
        case description
    }

    @FocusState private var focusedPart: Part?
    /// Whether the hygiene warning lists the flagged paths. Local,
    /// ephemeral UI state, never persisted.
    @State private var isHygieneWarningExpanded = false
    /// Set by Stop, so the end of the draft is announced as stopped.
    @State private var didStopDraft = false

    var body: some View {
        // The stack stays (empty) on a clean tree so that a draft started
        // from the menu is still announced.
        VStack(spacing: 0) {
            if let presentation = session.commitComposerPresentation(
                isDescriptionFocused: focusedPart == .description),
                presentation.isVisible
            {
                composer(presentation)
            }
        }
        .onChange(of: session.isGeneratingAICommitMessage) { _, isDrafting in
            announceDraftChange(isDrafting: isDrafting)
        }
        // The Commit menu item takes ⌘Return only while a message field has
        // focus, so ⌘Return in a terminal or the editor never commits.
        .focusedValue(\.commitComposerFocused, focusedPart != nil ? true : nil)
    }

    private func composer(_ presentation: GitCommitComposerPresentation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            messageField(presentation)
            if let error = session.aiCommitGenerationError {
                errorRow(error)
            }
            if !session.commitHygieneFindings.isEmpty {
                commitHygieneWarning(session.commitHygieneFindings)
            }
            actionButton(presentation)
        }
        .padding(.horizontal, RafuMetrics.sidebarTextInset)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    contrast == .increased ? theme.palette.borderStrong : theme.palette.borderSubtle
                )
                .frame(height: RafuMetrics.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Commit")
    }

    // MARK: Field

    private func messageField(_ presentation: GitCommitComposerPresentation) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                TextField("Summary", text: summaryBinding)
                    .textFieldStyle(.plain)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .focused($focusedPart, equals: .summary)
                    .onSubmit { focusedPart = .description }
                    .accessibilityLabel("Summary")
                    .accessibilityValue(presentation.summaryAccessibilityValue)
                summaryCounter(presentation)
                draftControl
            }
            .frame(minHeight: 22)
            if presentation.showsDescription {
                Rectangle()
                    .fill(theme.palette.borderSubtle)
                    .frame(height: RafuMetrics.hairline)
                    .padding(.vertical, 3)
                    .accessibilityHidden(true)
                TextField("Description", text: descriptionBinding, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .focused($focusedPart, equals: .description)
                    .accessibilityLabel("Description")
                    .padding(.bottom, 2)
            }
        }
        .rafuField(isFocused: focusedPart != nil)
        // D6: the drafting border has the field's own radius.
        .aiCommitGeneratingBorder(
            isActive: session.isGeneratingAICommitMessage, cornerRadius: RafuMetrics.radiusField)
    }

    @ViewBuilder
    private func summaryCounter(_ presentation: GitCommitComposerPresentation) -> some View {
        if let count = presentation.summaryCount {
            HStack(spacing: 2) {
                if presentation.isSummaryTooLong {
                    // The glyph says "too long" without colour alone.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                }
                Text("\(count)")
                    .font(.system(size: 10.5).monospacedDigit())
            }
            .foregroundStyle(
                presentation.isSummaryTooLong ? theme.palette.warning : theme.palette.textMuted
            )
            .help(
                presentation.isSummaryTooLong
                    ? "The summary is longer than \(GitCommitComposerPresentation.summaryLengthLimit) characters."
                    : "Summary length"
            )
            // The count is the summary field's accessibility value.
            .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var draftControl: some View {
        if session.isGeneratingAICommitMessage {
            HStack(spacing: 2) {
                ProgressView().controlSize(.mini)
                Button("Stop Generating", systemImage: "stop.fill") {
                    didStopDraft = true
                    session.cancelAICommitGeneration()
                }
                .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 10))
                .help("Stop generating the commit message.")
            }
        } else {
            // ⌥⌘G is the menu item's key (Source Control > Draft Message with
            // AI), so it is not registered a second time here.
            Button("Draft Message with AI", systemImage: "sparkles") {
                session.startAICommitGeneration()
            }
            .buttonStyle(RafuIconButtonStyle(size: 22, iconSize: 12))
            .disabled(!session.canGenerateAICommitMessage)
            .help(
                "Draft Message with AI (⌥⌘G). From \(session.aiCommitGenerationScopeDescription). No commit is created automatically."
            )
        }
    }

    private var summaryBinding: Binding<String> {
        Binding(
            get: { GitCommitMessageParts(message: session.gitCommitMessage).summary },
            set: {
                session.gitCommitMessage = GitCommitMessageParts.message(
                    session.gitCommitMessage, replacingSummary: $0)
            }
        )
    }

    private var descriptionBinding: Binding<String> {
        Binding(
            get: { GitCommitMessageParts(message: session.gitCommitMessage).description },
            set: {
                session.gitCommitMessage = GitCommitMessageParts.message(
                    session.gitCommitMessage, replacingDescription: $0)
            }
        )
    }

    // MARK: Error

    /// D8: the AI error has a recovery action. The usual cause is no
    /// provider or no key, both set in Settings > AI.
    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(theme.palette.error)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open AI Settings…") {
                SettingsPaneRouter.shared.request(.ai)
                openSettings()
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: Button

    @ViewBuilder
    private func actionButton(_ presentation: GitCommitComposerPresentation) -> some View {
        let button = Button {
            switch presentation.action {
            case .stageAll: Task { await session.stageAll() }
            case .commit: Task { await session.commit() }
            case .drafting: break
            }
        } label: {
            HStack(spacing: 4) {
                Text(presentation.buttonTitle)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let suffix = presentation.buttonBranchSuffix {
                    // A long branch name truncates; "Commit N Files" stays.
                    Text(suffix)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!presentation.isButtonEnabled)
        .help(presentation.buttonHelp)
        .accessibilityLabel(presentation.buttonAccessibilityLabel)
        .accessibilityHint(presentation.disabledReason ?? "")

        if presentation.isButtonProminent {
            button.buttonStyle(RafuProminentButtonStyle(quietWhenDisabled: true))
        } else {
            button.buttonStyle(RafuSecondaryButtonStyle())
        }
    }

    // MARK: Announcements

    private func announceDraftChange(isDrafting: Bool) {
        if isDrafting {
            didStopDraft = false
            AccessibilityNotification.Announcement("Drafting commit message").post()
            return
        }
        if let error = session.aiCommitGenerationError {
            AccessibilityNotification.Announcement("Draft failed: \(error)").post()
        } else if didStopDraft {
            AccessibilityNotification.Announcement("Draft stopped").post()
        } else {
            AccessibilityNotification.Announcement("Commit message drafted").post()
        }
        didStopDraft = false
    }

    // MARK: Hygiene

    /// Calm, advisory-only warning for `CommitHygieneChecker.findings` on the
    /// staged changeset. Never disables Commit — only informs, with an
    /// optional expansion listing each flagged path, its reason, and a
    /// per-row Unstage shortcut. No decorative animation.
    private func commitHygieneWarning(_ findings: [CommitHygieneFinding]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isHygieneWarningExpanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Label(
                        "\(findings.count) staged \(findings.count == 1 ? "file" : "files") may not belong in a commit",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption2)
                    .foregroundStyle(theme.palette.warning)
                    Spacer()
                    Image(systemName: isHygieneWarningExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(findings.count) staged files may not belong in a commit. Toggle details.")

            if isHygieneWarningExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(findings) { finding in
                        HStack(alignment: .top, spacing: 6) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(finding.path)
                                    .font(.caption2)
                                    .foregroundStyle(theme.palette.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text(finding.reason)
                                    .font(.caption2)
                                    .foregroundStyle(theme.palette.textSecondary)
                            }
                            Spacer(minLength: 4)
                            Button("Unstage") {
                                guard
                                    let change = session.gitSnapshot?.stagedChanges.first(where: {
                                        $0.path == finding.path
                                    })
                                else { return }
                                Task { await session.setStaged(false, change: change) }
                            }
                            .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                        }
                    }
                }
            }
        }
        .padding(8)
        .background(
            theme.palette.warning.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }
}
