import AppKit
import RafuCore
import SwiftUI

/// Settings > Agents > Agent History: which providers the History navigator
/// reads, and the folders it reads them from. A change rescans only if the
/// index was already loaded; Settings alone never starts a scan.
struct AgentHistorySettingsSection: View {
    @AppStorage(AgentHistoryStore.showsClaudeCodeKey) private var showsClaudeCode = true
    @AppStorage(AgentHistoryStore.showsCodexKey) private var showsCodex = true

    private let locations = AgentHistoryLocations.resolve()

    var body: some View {
        Section {
            Toggle("Show Claude Code history", isOn: $showsClaudeCode)
            AgentHistoryFolderRow(
                title: "Claude Code folder", url: locations.claudeProjectsDirectory)
            Toggle("Show Codex history", isOn: $showsCodex)
            AgentHistoryFolderRow(title: "Codex folder", url: locations.codexSessionsDirectory)
        } header: {
            Text("Agent History")
        } footer: {
            Text(
                "Rafu reads these transcripts on this Mac only. It never changes, uploads, or logs them. Set CLAUDE_CONFIG_DIR or CODEX_HOME before you open Rafu to use other folders."
            )
        }
        .onChange(of: showsClaudeCode) { _, _ in rescanIfLoaded() }
        .onChange(of: showsCodex) { _, _ in rescanIfLoaded() }
    }

    private func rescanIfLoaded() {
        let store = AgentHistoryStore.shared
        guard store.phase != .idle else { return }
        store.refresh()
    }
}

/// One resolved folder: the abbreviated path, and Show in Finder when it
/// exists.
private struct AgentHistoryFolderRow: View {
    let title: String
    let url: URL
    @State private var exists = false

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: RafuMetrics.space2) {
                Text(displayPath)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if exists {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                    .controlSize(.small)
                } else {
                    Text("Not found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: url) { exists = Self.folderExists(url) }
    }

    private var displayPath: String {
        AgentHistoryPath.abbreviated(url.path, home: NSHomeDirectory())
    }

    private static func folderExists(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}
