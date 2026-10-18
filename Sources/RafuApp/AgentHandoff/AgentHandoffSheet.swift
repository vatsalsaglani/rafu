import AppKit
import RafuCore
import SwiftUI

/// The review sheet for "Continue in Codex…" and "Continue in Claude Code…".
/// It shows exactly what Rafu will write. Nothing is written or started
/// until the user clicks "Write Handoff" or "Write & Start".
struct AgentHandoffSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rafuTheme) private var theme
    let session: WorkspaceSession
    @State private var model: AgentHandoffModel

    init(request: AgentHandoffRequest, session: WorkspaceSession) {
        self.session = session
        _model = State(
            initialValue: AgentHandoffModel(request: request, projectRoot: session.rootURL))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space4) {
            RafuSheetHeader(
                icon: "arrow.turn.up.right",
                title: "Continue in \(model.target.displayName)",
                subtitle:
                    "Rafu writes a Markdown handoff of this \(model.source.displayName) session into your project. Review it first."
            )
            content
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.warning)
                    .accessibilityLabel("Cannot write: \(message)")
            }
            AgentHandoffButtons(model: model, session: session, dismiss: { dismiss() })
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(minWidth: 560, idealWidth: 600, minHeight: 560, idealHeight: 700)
        .frame(maxHeight: .infinity, alignment: .top)
        .task { model.load() }
        .onDisappear { model.cancel() }
        .onChange(of: model.shouldDismiss) { _, shouldDismiss in
            if shouldDismiss { dismiss() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Reading session…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            RafuPanelEmptyState(
                icon: "exclamationmark.triangle", title: "Session Unavailable", message: message
            )
        case .ready:
            if case .written(let folder) = model.writeState {
                AgentHandoffWrittenView(model: model, session: session, folderName: folder)
            } else {
                AgentHandoffForm(model: model)
            }
        }
    }
}

// MARK: Form

private struct AgentHandoffForm: View {
    @Bindable var model: AgentHandoffModel

    var body: some View {
        Form {
            Section("Agent") {
                RafuSegmentedPicker(
                    items: AgentHistoryProvider.allCases, selection: $model.target,
                    fillsWidth: true
                ) { $0.displayName }
                .accessibilityLabel("Target agent")
            }
            Section("Turns") {
                RafuSegmentedPicker(
                    items: [AgentHandoffModel.RangeChoice.all, .last],
                    selection: $model.rangeChoice, fillsWidth: true
                ) { $0 == .all ? "All turns" : "Last turns" }
                .accessibilityLabel("Range")
                if model.rangeChoice == .last {
                    Stepper(
                        "Last \(model.lastTurnCount) turns", value: $model.lastTurnCount,
                        in: 1...500)
                }
            }
            Section("Include") {
                Toggle("Tool calls (one line each)", isOn: $model.includesToolCalls)
                Toggle("Tool outputs", isOn: $model.includesToolOutputs)
                LabeledContent("Thinking") { Text("Never included") }
            }
            AgentHandoffImagesSection(model: model)
            AgentHandoffWhereSection(model: model)
            AgentHandoffSummarySection(model: model)
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct AgentHandoffImagesSection: View {
    @Bindable var model: AgentHandoffModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Section("Images") {
            if model.imageRows.isEmpty {
                Text("No images in the chosen turns.")
                    .foregroundStyle(theme.palette.textSecondary)
            }
            ForEach(model.imageRows) { row in
                AgentHandoffImageRow(
                    row: row, thumbnail: model.thumbnails[row.id],
                    isIncluded: Binding(
                        get: { model.isImageIncluded(row.id) },
                        set: { model.setImage(row.id, included: $0) }))
            }
            if model.overLimitImageCount > 0 {
                Label(
                    "\(model.overLimitImageCount) older \(model.overLimitImageCount == 1 ? "image is" : "images are") over the limit of 20 and left out.",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            }
        }
    }
}

private struct AgentHandoffImageRow: View {
    let row: AgentHandoffModel.ImageRow
    let thumbnail: NSImage?
    @Binding var isIncluded: Bool
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Toggle(isOn: $isIncluded) {
            HStack(spacing: RafuMetrics.space3) {
                thumbnailView
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard))
                    .overlay(
                        RoundedRectangle(cornerRadius: RafuMetrics.radiusDenseCard)
                            .strokeBorder(theme.palette.borderSubtle)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Image \(row.number)")
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(theme.palette.textSecondary)
                }
            }
        }
        .disabled(!isUsable)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Image \(row.number), \(detail)")
        .accessibilityValue(isIncluded && isUsable ? "Included" : "Left out")
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFill()
        } else {
            Image(systemName: "photo")
                .foregroundStyle(theme.palette.textMuted)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var isUsable: Bool {
        if case .ready = row.status { return true }
        return false
    }

    private var detail: String {
        let origin = row.ref.isToolResult ? "from a tool result" : "from a message"
        switch row.status {
        case .loading:
            return "\(origin), loading"
        case .ready(let image):
            let size = ByteCountFormatter.string(
                fromByteCount: Int64(image.data.count), countStyle: .file)
            return "\(origin), \(image.format.fileExtension.uppercased()), \(size)"
        case .skipped(let reason):
            return "\(origin), left out: \(reason.note)"
        }
    }
}

private struct AgentHandoffWhereSection: View {
    @Bindable var model: AgentHandoffModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Section("Where") {
            LabeledContent("Folder") {
                Text(".rafu/handoffs/ in \(model.projectName)")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Toggle("Add .rafu/handoffs/ to .gitignore", isOn: $model.addsGitignore)
                .disabled(model.gitignoreState != .needsEntry)
            if let note = gitignoreNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
            }
            if model.sessionRanElsewhere {
                Label(
                    "This session ran in another folder. The new agent starts in \(model.projectName).",
                    systemImage: "info.circle"
                )
                .font(.caption)
                .foregroundStyle(theme.palette.textSecondary)
            }
        }
    }

    private var gitignoreNote: String? {
        switch model.gitignoreState {
        case .notGitRepository: "This folder is not a Git repository."
        case .alreadyIgnored: ".rafu/handoffs/ is already ignored."
        case .needsEntry: nil
        }
    }
}

private struct AgentHandoffSummarySection: View {
    let model: AgentHandoffModel
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Section("Summary") {
            if let document = model.document {
                Text(sizeText(document))
                    .accessibilityLabel(sizeText(document))
                if document.omittedBySize > 0 {
                    Label(
                        "\(document.omittedBySize) older turns do not fit the 200 KB limit and are left out.",
                        systemImage: "info.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                }
                if !model.attachments.isEmpty {
                    Text(
                        "\(model.attachments.count) mentioned files are listed in the handoff. Rafu does not copy them."
                    )
                    .font(.caption)
                    .foregroundStyle(theme.palette.textSecondary)
                }
            } else {
                Text("Preparing…").foregroundStyle(theme.palette.textSecondary)
            }
        }
    }

    private func sizeText(_ document: AgentHandoffDocument) -> String {
        let total = ByteCountFormatter.string(
            fromByteCount: Int64(model.estimatedTotalBytes), countStyle: .file)
        let turns =
            document.includedTurnCount == 1 ? "1 turn" : "\(document.includedTurnCount) turns"
        let images =
            document.imageFiles.count == 1 ? "1 image" : "\(document.imageFiles.count) images"
        return "About \(total): \(turns), \(images)."
    }
}

// MARK: Written

private struct AgentHandoffWrittenView: View {
    let model: AgentHandoffModel
    let session: WorkspaceSession
    let folderName: String
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        RafuPanelEmptyState(
            icon: "checkmark.circle", title: "Handoff Written",
            message: ".rafu/handoffs/\(folderName)/HANDOFF.md"
        ) {
            HStack(spacing: RafuMetrics.space2) {
                Button("Open HANDOFF.md") { open() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
                Button("Reveal in Finder") { reveal() }
                    .buttonStyle(RafuSecondaryButtonStyle(compact: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open() {
        guard let url = model.writtenResult?.markdownURL, let root = session.rootURL else { return }
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard AgentHistoryPath.isPath(path, inside: rootPath), path != rootPath else { return }
        session.openFile(atRelativePath: String(path.dropFirst(rootPath.count + 1)))
    }

    private func reveal() {
        guard let url = model.writtenResult?.markdownURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: Buttons

private struct AgentHandoffButtons: View {
    let model: AgentHandoffModel
    let session: WorkspaceSession
    let dismiss: () -> Void

    var body: some View {
        HStack {
            if case .written = model.writeState {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.writeState == .writing)
                Spacer()
                if model.writeState == .writing {
                    ProgressView().controlSize(.small)
                }
                Button("Write Handoff") { model.write(startAfter: false, session: session) }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .disabled(!model.canWrite)
                    .help("Write HANDOFF.md and the image files. Nothing starts.")
                Button("Write & Start") { model.write(startAfter: true, session: session) }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canWrite)
                    .help("Write the files, then start \(model.target.displayName) on them.")
            }
        }
    }
}

// MARK: Presentation

extension View {
    /// Shows the handoff review sheet for the window's pending request.
    func agentHandoffSheet(session: WorkspaceSession) -> some View {
        modifier(AgentHandoffSheetModifier(session: session))
    }
}

private struct AgentHandoffSheetModifier: ViewModifier {
    let session: WorkspaceSession

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { session.agentHistory.handoffRequest },
                set: { session.agentHistory.handoffRequest = $0 })
        ) { request in
            AgentHandoffSheet(request: request, session: session)
        }
    }
}

// MARK: Menu items

/// "Continue in Claude Code…" and "Continue in Codex…" for a session. Used
/// by the History row menu and the Agent Session tab's More menu. Menus use
/// system symbols only.
struct AgentHandoffMenuItems: View {
    let session: WorkspaceSession
    let summary: AgentHistorySessionSummary

    var body: some View {
        ForEach(AgentHistoryProvider.allCases, id: \.self) { target in
            Button("Continue in \(target.displayName)…", systemImage: "arrow.turn.up.right") {
                session.presentAgentHandoff(summary, target: target)
            }
        }
    }
}

/// "Hand off to Codex…" on a running Claude Code terminal card (and the
/// other way round). It uses the newest History session that ran in the
/// card's folder with the card's agent.
struct AgentHandoffCardMenuItems: View {
    let card: CanvasCard
    let board: CanvasBoardState
    let session: WorkspaceSession

    var body: some View {
        if let node = session.agentHandoffNode(for: card) {
            let target: AgentHistoryProvider = node.provider == .claudeCode ? .codex : .claudeCode
            Button("Hand off to \(target.displayName)…", systemImage: "arrow.turn.up.right") {
                session.presentAgentHandoff(fromCard: card.id, board: board, target: target)
            }
            .disabled(hasNoMatch)
            .help(
                hasNoMatch
                    ? "Agent History has no session for this folder and agent."
                    : "Write a handoff of the latest \(node.provider.displayName) session here and continue in \(target.displayName)."
            )
        }
    }

    /// Known only after History loaded once; before that the click loads it.
    private var hasNoMatch: Bool {
        AgentHistoryStore.shared.lastScanDate != nil
            && session.agentHandoffSession(for: card) == nil
    }
}
