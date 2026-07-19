import SwiftUI

/// The "Publish to GitHub" flow for a repository with no `origin` remote
/// yet: one explicit, user-confirmed action that creates the GitHub
/// repository, adds it as `origin`, and pushes the current branch in a
/// single `gh repo create … --push` call (see
/// `WorkspaceSession.publishToGitHub(name:visibility:)`). Errors surface
/// through the same Git-operation alert every other Git action already
/// uses (`WorkspaceSession.reportGitError`), so this sheet shows only a
/// busy state, never a duplicate inline error.
struct GitHubPublishSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var session: WorkspaceSession
    @State private var name: String
    @State private var visibility: GitHubRepositoryVisibility = .private

    init(session: WorkspaceSession) {
        self.session = session
        _name = State(initialValue: session.rootURL?.lastPathComponent ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RafuSheetHeader(
                icon: "arrow.up.doc.on.clipboard",
                title: "Publish to GitHub",
                subtitle: "Creates an origin remote and pushes the current branch."
            )

            Form {
                TextField("Repository name", text: $name)
                Picker("Visibility", selection: $visibility) {
                    Text("Private").tag(GitHubRepositoryVisibility.private)
                    Text("Public").tag(GitHubRepositoryVisibility.public)
                }
                .pickerStyle(.segmented)
            }
            .formStyle(.grouped)
            .disabled(session.isPublishingToGitHub)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .buttonStyle(RafuSecondaryButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .disabled(session.isPublishingToGitHub)
                Spacer()
                if session.isPublishingToGitHub {
                    ProgressView().controlSize(.small)
                }
                Button("Create & Push") {
                    let submittedName = name
                    let submittedVisibility = visibility
                    Task {
                        await session.publishToGitHub(
                            name: submittedName, visibility: submittedVisibility)
                    }
                }
                .buttonStyle(RafuProminentButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid || session.isPublishingToGitHub)
            }
        }
        .padding(RafuMetrics.sheetPadding)
        .frame(width: 440)
    }

    private var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
