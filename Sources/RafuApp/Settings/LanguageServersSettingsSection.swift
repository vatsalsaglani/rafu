import SwiftUI

/// Settings > Language Servers: the curated catalog, batching packs, and a
/// user's own custom entries. Thin — every list/action lives in
/// `LanguageServersCatalogModel`; this view only lays the rows out and
/// wires their button actions to `beginX()` model calls.
struct LanguageServersSettingsSection: View {
    @State private var model = LanguageServersCatalogModel()

    var body: some View {
        @Bindable var model = model

        Group {
            Section {
                ForEach(model.rows) { row in
                    LanguageServerCatalogRow(
                        row: row,
                        onInstall: { model.beginInstall(id: row.id) },
                        onUpdate: { model.beginUpdate(id: row.id) },
                        onUninstall: { model.beginUninstall(id: row.id) },
                        onCancel: { model.cancelInstall(id: row.id) }
                    )
                }
            } header: {
                HStack {
                    Text("Curated Servers")
                    Spacer()
                    Button("Refresh") { model.beginRefresh() }
                        .buttonStyle(.link)
                }
            } footer: {
                Text(
                    "Language servers are opt-in: Rafu only downloads and runs a server you "
                        + "explicitly install, and only for a workspace you've explicitly trusted."
                )
            }

            Section {
                DisclosureGroup("Packs") {
                    ForEach(model.packs) { pack in
                        LanguageServerPackRow(
                            pack: pack,
                            onInstall: { model.beginInstallPack(id: pack.id) },
                            onCancel: { model.cancelInstall(id: pack.id) }
                        )
                    }
                }
            }

            Section {
                ForEach(model.userRows) { row in
                    LanguageServerCatalogRow(
                        row: row,
                        onInstall: { model.beginInstall(id: row.id) },
                        onUpdate: { model.beginUpdate(id: row.id) },
                        onUninstall: { model.beginUninstall(id: row.id) },
                        onCancel: { model.cancelInstall(id: row.id) },
                        onRemove: { model.beginRemoveUserEntry(id: row.id) }
                    )
                }
                Button("Add Custom Server…") { model.isPresentingEntryForm = true }
            } header: {
                Text("Custom Servers")
            }
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
