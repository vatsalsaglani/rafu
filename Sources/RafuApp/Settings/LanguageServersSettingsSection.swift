import SwiftUI

/// Settings > Language Servers: the curated catalog as one table (Server,
/// Languages, Status, Size, Action), the batching packs, a user's own custom
/// entries, and workspace trust. Thin — every list/action lives in
/// `LanguageServersCatalogModel`; this view only lays the rows out and
/// wires their button actions to `beginX()` model calls.
struct LanguageServersSettingsSection: View {
    @State private var model = LanguageServersCatalogModel()
    @State private var trustModel = WorkspaceTrustSettingsModel()

    var body: some View {
        @Bindable var model = model

        Group {
            Section {
                LanguageServerTable(rows: model.rows, model: model, showsRemove: false)
            } header: {
                HStack {
                    Text("Curated Servers")
                    Spacer()
                    Button {
                        model.beginRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help("Refresh")
                    .accessibilityLabel("Refresh")
                }
            } footer: {
                Text(
                    "Language servers are opt-in: Rafu only downloads and runs a server you "
                        + "explicitly install, and only for a workspace you've explicitly trusted."
                )
            }

            Section("Packs") {
                ForEach(model.packs) { pack in
                    LanguageServerPackRow(
                        pack: pack,
                        onInstall: { model.beginInstallPack(id: pack.id) },
                        onCancel: { model.cancelInstall(id: pack.id) }
                    )
                }
            }

            Section("Custom Servers") {
                if !model.userRows.isEmpty {
                    LanguageServerTable(rows: model.userRows, model: model, showsRemove: true)
                }
                Button("Add Custom Server…") { model.isPresentingEntryForm = true }
            }

            Section {
                if trustModel.rows.isEmpty {
                    Text("No workspaces have approved a language server yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(trustModel.rows) { row in
                        WorkspaceTrustApprovalRow(row: row, onRevoke: { trustModel.revoke(row) })
                    }
                }
            } header: {
                Text("Workspace Trust")
            } footer: {
                Text(
                    "Revoking takes effect the next time the workspace is reopened; a server "
                        + "already running for that workspace keeps running until it idles out "
                        + "or the workspace reopens."
                )
            }
        }
        .task { await trustModel.load() }
        .alert(
            "Workspace Trust Error",
            isPresented: Binding(
                get: { trustModel.presentedError != nil },
                set: { isPresented in
                    if !isPresented { trustModel.presentedError = nil }
                }
            )
        ) {
            Button("OK") { trustModel.presentedError = nil }
        } message: {
            Text(trustModel.presentedError ?? "")
        }
        .sheet(isPresented: $model.isPresentingEntryForm) {
            UserServerEntryForm(model: model)
        }
        .sheet(item: $model.presentedConsent) { consent in
            ServerInstallConsentView(
                request: consent,
                onCancel: { model.presentedConsent = nil },
                onInstall: {
                    switch consent.subject {
                    case .server: model.confirmInstall()
                    case .pack: model.confirmInstallPack()
                    }
                }
            )
        }
        .alert(
            "Language Server Error",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { isPresented in
                    if !isPresented { model.presentedError = nil }
                }
            )
        ) {
            Button("OK") { model.presentedError = nil }
        } message: {
            Text(model.presentedError ?? "")
        }
        .task { await model.load() }
    }
}

/// Pure text and sizing rules for the server table, kept apart from the views
/// so a test can pin them.
nonisolated enum LanguageServerTablePresentation {
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 30
    static let maximumHeight: CGFloat = 360

    /// Tall enough for every row without an inner scroll bar, up to a cap.
    static func tableHeight(rowCount: Int) -> CGFloat {
        min(maximumHeight, headerHeight + rowHeight * CGFloat(max(rowCount, 1)))
    }

    static func statusText(_ state: LanguageServersCatalogModel.InstallState) -> String {
        switch state {
        case .notInstalled: "Not installed"
        case .installed(let version): "Installed · \(version)"
        case .availableViaToolchain: "Available via toolchain"
        case .unavailableToolchain: "Toolchain not found"
        case .prerequisiteMissing: "Prerequisite missing"
        }
    }

    static func sizeText(_ source: ServerSource?) -> String {
        guard let source else { return "—" }
        guard let bytes = source.estimatedBytes else { return "Unknown" }
        return Int64(bytes).formatted(.byteCount(style: .file))
    }
}

/// One table of servers: Server, Languages, Status, Size, Action.
private struct LanguageServerTable: View {
    let rows: [LanguageServersCatalogModel.CatalogRowState]
    let model: LanguageServersCatalogModel
    let showsRemove: Bool

    var body: some View {
        Table(rows) {
            TableColumn("Server") { row in
                Text(row.descriptor.displayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Languages") { row in
                Text(row.descriptor.languageIDs.joined(separator: ", "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(row.descriptor.languageIDs.joined(separator: ", "))
            }
            .width(min: 80, ideal: 130)
            TableColumn("Status") { row in
                Text(LanguageServerTablePresentation.statusText(row.installState))
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)
            TableColumn("Size") { row in
                Text(LanguageServerTablePresentation.sizeText(row.descriptor.source))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 56, ideal: 66, max: 90)
            TableColumn("Action") { row in
                LanguageServerActions(row: row, model: model, showsRemove: showsRemove)
            }
            .width(min: 120, ideal: 150)
        }
        .frame(height: LanguageServerTablePresentation.tableHeight(rowCount: rows.count))
    }
}

/// The action cluster for one server row, chosen by install state.
private struct LanguageServerActions: View {
    let row: LanguageServersCatalogModel.CatalogRowState
    let model: LanguageServersCatalogModel
    let showsRemove: Bool

    var body: some View {
        if row.progressActive {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Button("Cancel", role: .cancel) { model.cancelInstall(id: row.id) }
            }
        } else {
            HStack(spacing: 8) {
                switch row.installState {
                case .notInstalled:
                    Button("Install…") { model.beginInstall(id: row.id) }
                case .installed:
                    Button("Update") { model.beginUpdate(id: row.id) }
                    Button("Uninstall", role: .destructive) { model.beginUninstall(id: row.id) }
                case .availableViaToolchain:
                    Text("Available").foregroundStyle(.secondary)
                case .unavailableToolchain, .prerequisiteMissing:
                    Text("Not Available").foregroundStyle(.secondary)
                }
                if showsRemove {
                    Button("Remove", role: .destructive) {
                        model.beginRemoveUserEntry(id: row.id)
                    }
                }
            }
            .buttonStyle(.borderless)
        }
    }
}

/// One workspace's approval of one server id: the workspace's last path
/// component prominently, its full path as secondary text, the approved
/// server id, and a destructive "Revoke" action. Pure display plus a
/// button action — no I/O.
private struct WorkspaceTrustApprovalRow: View {
    let row: WorkspaceTrustSettingsModel.TrustApprovalRow
    let onRevoke: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.workspaceDisplayName)
                    .font(.body.weight(.medium))
                Text(row.workspaceKey)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(row.serverID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revoke", role: .destructive) { onRevoke() }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(row.workspaceDisplayName), approved \(row.serverID)"))
        .accessibilityValue(Text(row.workspaceKey))
    }
}
