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
        Group {
            if session.conductorRuns.isEmpty {
                ContentUnavailableView {
                    Label("No Runs Yet", systemImage: WorkspaceNavigatorMode.runs.symbolName)
                } description: {
                    Text(
                        "Conductor runs appear here once a run has been started. Rafu never starts one on its own."
                    )
                }
            } else {
                List(session.conductorRuns, id: \.id, selection: runSelection) { run in
                    ConductorRunRow(run: run)
                        .tag(run.id)
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            Text(run.worktreeBranch)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
