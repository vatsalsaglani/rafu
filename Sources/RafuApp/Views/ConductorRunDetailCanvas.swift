import SwiftUI

/// Editor-hosted run detail — PLACEHOLDER. C5 owns the real timeline, gates,
/// and diff review (`docs/plans/phases/conductor/C5-pipelines.md`).
///
/// ADR 0002/0003's pattern: run STRUCTURE lives in the navigator panel,
/// run DETAIL lives in the editor canvas, never in a permanent inspector.
/// C0 lands the type only; nothing routes an editor tab here until C5 owns
/// the tab kind, so this file stays a pure, isolated placeholder.
struct ConductorRunDetailCanvas: View {
    let manifest: ConductorRunManifest?

    var body: some View {
        Group {
            if let manifest {
                VStack(alignment: .leading, spacing: 6) {
                    Text(manifest.workflowName).font(.title3.weight(.semibold))
                    Text("Run \(manifest.id) on \(manifest.worktreeBranch)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("The run timeline arrives with the pipelines phase.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .scenePadding()
            } else {
                ContentUnavailableView(
                    "No Run Selected",
                    systemImage: WorkspaceNavigatorMode.runs.symbolName,
                    description: Text("Choose a run in the Runs navigator to see its detail.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
