import SwiftUI

/// The "Add a custom server" sheet: either an HTTPS release-asset download
/// or an already-installed local binary. Submission delegates every
/// validation decision to `LanguageServersCatalogModel.addUserEntry(_:)` —
/// this view only collects and displays the fields and any resulting
/// error, never builds or persists a `ServerDescriptor` itself.
struct UserServerEntryForm: View {
    @Bindable var model: LanguageServersCatalogModel
    @State private var isSubmitting = false

    var body: some View {
        Form {
            Section("Server") {
                TextField("Server ID (unique)", text: $model.entryDraft.id)
                TextField("Display Name", text: $model.entryDraft.displayName)
                TextField("Language IDs (comma-separated)", text: $model.entryDraft.languageIDsText)
                TextField(
                    "Launch Arguments (space-separated)",
                    text: $model.entryDraft.launchArgumentsText
                )
            }

            Section("Source") {
                Picker("Source", selection: $model.entryDraft.sourceKind) {
                    Text("HTTPS Release Asset")
                        .tag(
                            LanguageServersCatalogModel.UserEntryDraft.SourceKind.httpsReleaseAsset)
                    Text("Local Binary")
                        .tag(LanguageServersCatalogModel.UserEntryDraft.SourceKind.localBinary)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.entryDraft.sourceKind {
                case .httpsReleaseAsset:
                    httpsFields
                case .localBinary:
                    localBinaryFields
                }
            }

            if let error = model.presentedError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.isPresentingEntryForm = false }
                        .keyboardShortcut(.cancelAction)
                    Button("Add") { submit() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                        .disabled(isSubmitting)
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 420, minHeight: 460)
    }

    @ViewBuilder
    private var httpsFields: some View {
        TextField("Asset URL (https://…)", text: $model.entryDraft.assetURLText)
        TextField("Version", text: $model.entryDraft.version)
        TextField("License", text: $model.entryDraft.license)
        Picker("Archive Format", selection: $model.entryDraft.archiveFormat) {
            Text("Raw Binary").tag(ArchiveFormat.rawBinary)
            Text("Gzip").tag(ArchiveFormat.gzip)
            Text("Zip").tag(ArchiveFormat.zip)
            Text("Tar + Gzip").tag(ArchiveFormat.tarGzip)
        }
        TextField("Binary Path Inside Archive", text: $model.entryDraft.binaryRelativePath)
    }

    @ViewBuilder
    private var localBinaryFields: some View {
        TextField("Binary Path", text: $model.entryDraft.localBinaryPathText)
        TextField("License", text: $model.entryDraft.license)
        Text(
            "Local-binary servers are stored, but Rafu's current launch support for them is "
                + "limited; a future update completes this path."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func submit() {
        isSubmitting = true
        let draft = model.entryDraft
        Task {
            defer { isSubmitting = false }
            do {
                try await model.addUserEntry(draft)
            } catch {
                model.presentedError = LanguageServersCatalogModel.message(for: error)
            }
        }
    }
}
