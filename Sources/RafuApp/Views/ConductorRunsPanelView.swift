import SwiftUI

/// `.runs` navigator panel — PLACEHOLDER. C5 owns the real run list and
/// timeline (`docs/plans/phases/conductor/C5-pipelines.md`); C0 lands only
/// the mounted surface so the rail button, the navigator case, and the
/// window layout are all real and reviewable now.
///
/// The empty state expands to fill (`maxWidth`/`maxHeight: .infinity`) — a
/// panel whose content does not expand drags its own header and tab strip to
/// the vertical middle (AGENTS.md, panel top-pinning rule).
struct ConductorRunsPanelView: View {
    @Bindable var session: WorkspaceSession

    var body: some View {
        @Bindable var controller = session.conductorRunController

        VStack(spacing: 0) {
            if let error = controller.runsLoadError {
                ContentUnavailableView {
                    Label("Unable to Load Runs", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") {
                        Task { await controller.reloadRuns() }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if session.conductorRuns.isEmpty {
                ContentUnavailableView {
                    Label("No Runs Yet", systemImage: WorkspaceNavigatorMode.runs.symbolName)
                } description: {
                    Text(
                        "Ensemble runs appear here once a run has been started. Rafu never starts one on its own."
                    )
                } actions: {
                    Button("New Run…", systemImage: "plus") {
                        controller.presentNewRun()
                    }
                    .disabled(!controller.canStartNewRun)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Spacer()
                    Button("New Run…", systemImage: "plus") {
                        controller.presentNewRun()
                    }
                    .disabled(!controller.canStartNewRun)
                }
                .padding(8)
                Divider()
                List(session.conductorRuns, id: \.id, selection: runSelection) { run in
                    ConductorRunRow(run: run)
                        .tag(run.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.rootURL?.standardizedFileURL) {
            await controller.attachAndReload(workspaceRoot: session.rootURL)
        }
        .sheet(item: $controller.newRunPresentation) { _ in
            ConductorNewRunSheet(session: session)
        }
    }

    private var runSelection: Binding<String?> {
        Binding(
            get: { session.selectedConductorRunID },
            set: { newValue in
                guard let newValue else { return }
                session.openConductorRun(newValue)
            })
    }
}

private struct ConductorRunRow: View {
    let run: ConductorRunManifest

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(run.workflowName).font(.body.weight(.medium))
            Text("\(statusDescription) · \(workspaceDescription)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var workspaceDescription: String {
        run.worktreeBranch.isEmpty ? "Main workspace" : run.worktreeBranch
    }

    private var statusDescription: String {
        guard let status = run.steps.first?.status else { return "Pending" }
        return switch status {
        case .pending: "Pending"
        case .running: "Running"
        case .awaitingGate: "Awaiting merge gate"
        case .completed: "Completed"
        case .failed: "Failed"
        case .aborted: "Aborted"
        }
    }
}

private struct ConductorNewRunSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @State private var model = ConductorNewRunModel()
    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Ensemble Run")
                    .font(.title2.weight(.semibold))
                Text("Choose a repository role. Rafu starts nothing until you select Run.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if model.isLoading {
                ProgressView("Reading agent files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.agents.isEmpty, model.errorMessage == nil {
                ContentUnavailableView {
                    Label("No Agent Files", systemImage: "person.crop.rectangle.stack")
                } description: {
                    Text("Add a Markdown role under .rafu/agents/ to start a run.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Picker("Agent file", selection: $model.selectedAgentID) {
                        ForEach(model.agents) { agent in
                            Text("\(agent.definition.name) — \(agent.relativePath)")
                                .tag(Optional(agent.id))
                        }
                    }
                    TextField("Task prompt", text: $model.taskPrompt, axis: .vertical)
                        .lineLimit(4...8)
                        .focused($promptFocused)
                    TextField("Base reference", text: $model.baseReference)
                        .help("Branch, tag, or commit. Defaults to the current HEAD.")
                }
                .formStyle(.grouped)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Run error: \(error)")
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        if await model.start(in: session) {
                            dismiss()
                        }
                    }
                } label: {
                    if model.isStarting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Run")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canStart)
            }
        }
        .padding(20)
        .frame(minWidth: 500, idealWidth: 500, minHeight: 380)
        .task(id: session.rootURL?.standardizedFileURL) {
            await model.load(workspaceRoot: session.rootURL)
            if !model.agents.isEmpty {
                promptFocused = true
            }
        }
    }
}
