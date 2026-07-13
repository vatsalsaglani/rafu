import RafuCore
import SwiftUI
import UniformTypeIdentifiers

struct WorkspaceWindowView: View {
    @Bindable var session: WorkspaceSession
    @State private var navigationSplitVisibility = NavigationSplitViewVisibility.all
    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView(columnVisibility: $navigationSplitVisibility) {
                WorkspaceSidebarView(session: session)
            } detail: {
                HStack(spacing: 0) {
                    // H/VSplitView are AppKit-backed and collapse to their
                    // children's ideal size unless every level is forced to
                    // fill; keep the explicit max frames and layout priority.
                    HSplitView {
                        VSplitView {
                            editorCanvas
                                .frame(minWidth: 480, minHeight: 220)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            if session.isTerminalPresented {
                                WorkspaceTerminalPanel(session: session)
                                    .frame(minHeight: 130, idealHeight: 240, maxHeight: 520)
                                    .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(minWidth: 480)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .layoutPriority(1)
                        if session.descriptor != nil, session.navigatorMode != .files {
                            WorkspaceUtilityPanelView(session: session)
                                .frame(minWidth: 250, idealWidth: 310, maxWidth: 460)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(1)
                    Divider().overlay(theme.palette.borderSubtle)
                    WorkspaceUtilityRail(session: session)
                }
            }
            .navigationSplitViewStyle(.balanced)

            Divider()
            WorkspaceStatusBar(descriptor: session.descriptor)
        }
        .frame(minWidth: 720, minHeight: 480)
        .navigationTitle(session.windowTitle)
        .focusedSceneValue(\.workspaceSession, session)
        .fileImporter(
            isPresented: $session.isOpenFolderImporterPresented,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else {
                    return
                }
                session.openLocalWorkspace(at: url)
            case .failure(let error):
                session.reportOpenFolderError(error)
            }
        }
        .alert("Unable to Open Folder", isPresented: $session.isOpenFolderErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.openFolderErrorMessage)
        }
        .sheet(isPresented: $session.isCommandPalettePresented) {
            CommandPaletteView(session: session)
        }
        .sheet(isPresented: $session.isQuitConfirmationPresented) {
            EmptyWindowQuitConfirmationView()
        }
        .alert("Command Line Tool", isPresented: cliMessageBinding) {
            Button("OK", role: .cancel) { session.cliInstallMessage = nil }
        } message: {
            Text(session.cliInstallMessage ?? "")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Open Folder", systemImage: "folder.badge.plus") {
                    session.requestOpenFolder()
                }
                .help("Open a local workspace folder")
            }
        }
    }

    private var editorCanvas: some View {
        EditorCanvasView(
            session: session,
            openFolder: session.requestOpenFolder
        )
    }

    private var cliMessageBinding: Binding<Bool> {
        Binding(
            get: { session.cliInstallMessage != nil },
            set: { if !$0 { session.cliInstallMessage = nil } }
        )
    }
}

private struct EmptyWindowQuitConfirmationView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var neverAskAgain = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Quit Rafu?", systemImage: "questionmark.circle")
                .font(.title3.weight(.semibold))
            Text("No editor tabs are open in this window.")
                .foregroundStyle(.secondary)
            Toggle("Don’t ask again when the last editor is closed", isOn: $neverAskAgain)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Quit") {
                    if neverAskAgain {
                        UserDefaults.standard.set(
                            true,
                            forKey: "quitWithoutEmptyWindowConfirmation"
                        )
                    }
                    NSApp.terminate(nil)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 430)
    }
}
