import SwiftUI
import UniformTypeIdentifiers

/// Full Agent Terminal launch flow. The sheet owns only ephemeral choices;
/// adapter probing and process-spec construction stay in the launch service.
struct AgentTerminalSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.rafuTheme) private var theme
    @Bindable var session: WorkspaceSession

    @State private var options: [AgentTerminalOption] = []
    @State private var selectedID: ConductorCLIID?
    @State private var model = ""
    @State private var startingDirectory: URL
    @State private var directoryImporterPresented = false
    @State private var validationMessage: String?

    init(session: WorkspaceSession) {
        self.session = session
        _startingDirectory = State(
            initialValue: session.rootURL
                ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "terminal.badge",
                title: "New Agent Terminal",
                subtitle: "Launch an installed agent CLI interactively in this workspace."
            )

            if options.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking installed agent CLIs…")
                        .foregroundStyle(theme.palette.textSecondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                agentPicker
                launchConfiguration
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(theme.palette.warning)
                    .accessibilityLabel("Cannot launch: \(validationMessage)")
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Launch") { launch() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(selectedOption?.isReady != true)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 440)
        .task {
            await loadOptions()
        }
        .fileImporter(
            isPresented: $directoryImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            chooseStartingDirectory(result)
        }
    }

    private var agentPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Agent")
                .font(.headline)
            ForEach(options) { option in
                AgentTerminalPickerRow(
                    option: option,
                    isSelected: selectedID == option.id,
                    select: { select(option) }
                )
            }
        }
    }

    private var launchConfiguration: some View {
        Form {
            LabeledContent("Model") {
                HStack {
                    TextField("Model ID", text: $model)
                    if let option = selectedOption, !option.curatedModels.isEmpty {
                        Menu("Models") {
                            ForEach(option.curatedModels, id: \.self) { modelID in
                                Button(modelID) { model = modelID }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }

            LabeledContent("Starting directory") {
                HStack {
                    Text(startingDirectoryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(theme.palette.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Choose…") {
                        directoryImporterPresented = true
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay(alignment: .bottomLeading) {
            if let note = selectedOption?.launchVerificationNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(theme.palette.textMuted)
                    .padding(.horizontal, 10)
                    .offset(y: 13)
            }
        }
        .padding(.bottom, selectedOption?.launchVerificationNote == nil ? 0 : 20)
    }

    private var selectedOption: AgentTerminalOption? {
        options.first { $0.id == selectedID }
    }

    private var startingDirectoryLabel: String {
        guard let root = session.rootURL else { return startingDirectory.path }
        return TerminalSessionPresentation.directoryLabel(
            path: startingDirectory.path, workspaceRoot: root.path)
    }

    private func loadOptions() async {
        guard let root = session.rootURL else { return }
        let loaded = await AgentTerminalLaunchService(workspaceRoot: root).options()
        guard !Task.isCancelled else { return }
        options = loaded
        if let firstReady = loaded.first(where: \.isReady) {
            select(firstReady)
        } else if let first = loaded.first {
            select(first)
        }
    }

    private func select(_ option: AgentTerminalOption) {
        selectedID = option.id
        model = option.defaultModel ?? ""
        validationMessage = nil
    }

    private func chooseStartingDirectory(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let directory = urls.first, let root = session.rootURL else { return }
            guard AgentTerminalLaunchService.isStartingDirectory(directory, inside: root) else {
                validationMessage = "Choose a directory inside \(root.lastPathComponent)."
                return
            }
            startingDirectory = directory.standardizedFileURL
            validationMessage = nil
        case .failure(let error):
            validationMessage = error.localizedDescription
        }
    }

    private func launch() {
        guard let root = session.rootURL, let selectedOption else { return }
        do {
            let specification = try AgentTerminalLaunchService(workspaceRoot: root).specification(
                option: selectedOption,
                model: model,
                startingDirectory: startingDirectory)
            session.openAgentTerminal(spec: specification)
            dismiss()
        } catch AgentTerminalLaunchError.startingDirectoryOutsideWorkspace {
            validationMessage = "Choose a starting directory inside the workspace."
        } catch {
            validationMessage = "This agent CLI is not ready to launch."
        }
    }
}

private struct AgentTerminalPickerRow: View {
    let option: AgentTerminalOption
    let isSelected: Bool
    let select: () -> Void

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                FileIconView(icon: option.icon, size: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(theme.palette.textPrimary)
                    if let reason = option.availability.reason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(theme.palette.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(theme.palette.accent)
                        .accessibilityLabel("Selected")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .fill(isSelected ? theme.palette.selection : theme.palette.cardBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: RafuMetrics.radiusControl, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.palette.accent : theme.palette.borderSubtle)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!option.isReady)
        .help(option.availability.reason ?? "Launch \(option.displayName)")
        .accessibilityLabel(
            option.availability.reason.map { "\(option.displayName), \($0)" }
                ?? option.displayName
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
