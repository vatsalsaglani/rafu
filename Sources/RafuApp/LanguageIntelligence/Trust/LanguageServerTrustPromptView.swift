import SwiftUI

/// A pending request to run one specific, installed-but-untrusted language
/// server for the current workspace, raised by
/// `LanguageIntelligenceCoordinator.session(forLanguageID:)` when a
/// navigation request would otherwise silently decline. Cleared only by an
/// explicit `approveTrust(_:)` or `declineTrust(_:)` call — never
/// dismissed automatically.
nonisolated struct TrustRequest: Identifiable, Sendable, Equatable {
    var id: String { serverID }
    let serverID: String
    let displayName: String
    let languageID: String
}

/// A reusable "run this server for this workspace?" prompt. Built for the
/// C4 trust flow but **not mounted in any window this increment** — see
/// the phase brief's deferred-to-integration note: reaching a live
/// `WorkspaceSession`/window from `LanguageIntelligenceCoordinator` needs a
/// `Views/`-owned edit outside lane 2's C4 owned paths. A future
/// integration round mounts this as a sheet/alert keyed by
/// `coordinator.pendingTrustRequest`.
struct LanguageServerTrustPromptView: View {
    let request: TrustRequest
    let onApprove: (TrustRequest) -> Void
    let onDecline: (TrustRequest) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Run \(request.displayName) for this workspace?")
                .font(.headline)
            Text(
                "\(request.displayName) will start automatically to provide code intelligence "
                    + "for \(request.languageID) files in this workspace, until you change this "
                    + "in Settings > Language Servers."
            )
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            HStack {
                Spacer()
                Button("Decline") { onDecline(request) }
                    .keyboardShortcut(.cancelAction)
                Button("Trust") { onApprove(request) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 360)
    }
}
