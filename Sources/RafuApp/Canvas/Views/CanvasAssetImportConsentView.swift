import SwiftUI

extension View {
    /// Presents the "copy external images into the workspace" consent for
    /// `board`'s pending import (`CanvasBoardState.pendingAssetImport`).
    func canvasAssetImportConsent(board: CanvasBoardState, session: WorkspaceSession) -> some View {
        modifier(CanvasAssetImportConsentModifier(board: board, session: session))
    }
}

private struct CanvasAssetImportConsentModifier: ViewModifier {
    let board: CanvasBoardState
    let session: WorkspaceSession

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(
                get: { board.pendingAssetImport },
                set: { value in
                    // Dismissed by any route other than the buttons: cancel.
                    if value == nil, let request = board.pendingAssetImport {
                        session.cancelCanvasAssetImport(request)
                    }
                })
        ) { request in
            CanvasAssetImportConsentView(
                request: request,
                onCancel: { session.cancelCanvasAssetImport(request) },
                onCopy: { alwaysCopy in
                    Task {
                        await session.confirmCanvasAssetImport(request, alwaysCopy: alwaysCopy)
                    }
                })
        }
    }
}

/// The consent for copying images from outside the workspace. Kept as one
/// small view with plain inputs (a request, two callbacks) so it can move
/// to the shared Rafu popup components later without touching the flow.
struct CanvasAssetImportConsentView: View {
    let request: CanvasAssetImportRequest
    let onCancel: () -> Void
    let onCopy: (_ alwaysCopy: Bool) -> Void
    @State private var alwaysCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            Text(
                request.imageCount == 1
                    ? "The image comes from outside this workspace. The copy becomes part of this workspace, and the card shows the copy."
                    : "The images come from outside this workspace. The copies become part of this workspace, and the cards show the copies."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Toggle("Always copy without asking in this workspace", isOn: $alwaysCopy)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Copy") { onCopy(alwaysCopy) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
