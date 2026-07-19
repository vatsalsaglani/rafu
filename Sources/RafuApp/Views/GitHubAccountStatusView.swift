import SwiftUI

/// Global, per-window status-bar chip reading `GitHubAccountModel.shared`.
/// Text-first always: the login name is always the visible label, and a
/// best-effort avatar (see `GitHubAccountModel.avatarImage`) is only ever an
/// addition next to it, never a replacement — a missing/failed avatar fetch
/// silently falls back to a glyph, never to a blank chip.
struct GitHubAccountStatusView: View {
    @Bindable var session: WorkspaceSession
    @Environment(\.rafuTheme) private var theme

    private var model: GitHubAccountModel { GitHubAccountModel.shared }

    var body: some View {
        Group {
            switch model.state {
            case .signedIn(let account):
                Menu {
                    Button("Refresh") {
                        Task { await model.refresh() }
                    }
                    Button("Publish to GitHub…") {
                        session.isGitHubPublishPresented = true
                    }
                    .disabled(!session.canPublishToGitHub)
                } label: {
                    HStack(spacing: 5) {
                        avatarGlyph
                        Text(account.login).lineLimit(1)
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Signed in to GitHub as \(account.login)")
                .accessibilityLabel("GitHub account \(account.login)")

            case .signedOut:
                Button {
                    Task { await model.refresh() }
                } label: {
                    Text("GitHub: sign in")
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.palette.textMuted)
                .help(
                    "Run “gh auth login” in a terminal, then click to refresh. Rafu never runs interactive sign-in."
                )
                .accessibilityLabel("Not signed in to GitHub. Run gh auth login in a terminal.")

            case .cliMissing, .unknown:
                EmptyView()
            }
        }
        .font(.caption)
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var avatarGlyph: some View {
        if let avatarImage = model.avatarImage {
            Image(nsImage: avatarImage)
                .resizable()
                .scaledToFill()
                .frame(width: 14, height: 14)
                .clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(theme.palette.textMuted)
        }
    }
}
