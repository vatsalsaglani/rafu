import SwiftUI

/// Pure "does the form differ from what is saved" rule behind the Save
/// button's default state. Text is compared trimmed, the way `validated()`
/// normalizes it, so stray whitespace alone does not count as a change.
nonisolated enum AIProviderDraftChange {
    static func hasChanges(
        saved: AIProviderConfiguration,
        name: String,
        kind: AIProviderKind,
        baseURL: String,
        model: String,
        modelAlias: String,
        transport: OpenAICompatibleTransport,
        maxOutputTokens: Int,
        enteredAPIKey: String
    ) -> Bool {
        func trimmed(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if !trimmed(enteredAPIKey).isEmpty { return true }
        return trimmed(name) != trimmed(saved.name)
            || kind != saved.kind
            || trimmed(baseURL) != saved.baseURL.absoluteString
            || trimmed(model) != trimmed(saved.model)
            || trimmed(modelAlias) != trimmed(saved.modelAlias ?? "")
            || transport != saved.openAITransport
            || maxOutputTokens != saved.maxOutputTokens
    }
}

/// Settings > AI: a provider list with "+" and "−" beneath it (the macOS
/// list-edit convention) beside a detail form with right-aligned labels.
struct AIProviderSettingsSection: View {
    @State private var model: AIProviderSettingsModel

    init(model: AIProviderSettingsModel = AIProviderSettingsModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model

        Section {
            HStack(alignment: .top, spacing: 16) {
                providerList(model: model)
                    .frame(width: 180)
                VStack(alignment: .leading, spacing: 14) {
                    providerFields(model: model)
                    actionRow(model: model)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Commit Message Providers")
        } footer: {
            Text(
                "Keys stay in this Mac’s Keychain. Only explicitly selected diffs are sent when "
                    + "you ask Rafu to generate a commit message."
            )
        }
        .task { await model.load() }
    }

    // MARK: Provider list

    private func providerList(model: AIProviderSettingsModel) -> some View {
        VStack(spacing: 0) {
            List(
                model.configurations,
                selection: Binding<UUID?>(
                    get: { model.selectedID },
                    set: { id in
                        guard let id, id != model.selectedID else { return }
                        model.beginSelect(id)
                    }
                )
            ) { configuration in
                VStack(alignment: .leading, spacing: 1) {
                    Text(configuration.name).lineLimit(1)
                    Text(configuration.displayModelName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .listStyle(.bordered)
            .frame(height: 190)
            .accessibilityLabel("Providers")

            HStack(spacing: 0) {
                Menu {
                    ForEach(AIProviderKind.allCases) { kind in
                        Button(kind.title) { model.add(kind) }
                    }
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 24, height: 20)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Add Provider")
                .accessibilityLabel("Add Provider")

                Button {
                    model.beginDelete()
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 24, height: 20)
                }
                .buttonStyle(.borderless)
                .disabled(model.selectedID == nil)
                .help("Remove Selected Provider")
                .accessibilityLabel("Remove Selected Provider")

                Spacer(minLength: 0)
            }
            .padding(.top, 4)
        }
    }

    // MARK: Detail form

    private func providerFields(model: AIProviderSettingsModel) -> some View {
        @Bindable var model = model

        return Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            fieldRow("Name") { TextField("Provider name", text: $model.draftName) }
            fieldRow("Provider") {
                Picker("Provider", selection: $model.draftKind) {
                    ForEach(AIProviderKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .fixedSize()
                .onChange(of: model.draftKind) { oldValue, newValue in
                    if oldValue != newValue { model.applyKindDefaults(newValue) }
                }
            }
            fieldRow("Base URL") { TextField("https://…", text: $model.draftBaseURL) }
            fieldRow("Model ID") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField("Exact model identifier, e.g. gpt-5.2", text: $model.draftModel)
                    Text("Sent to the provider exactly as typed.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            fieldRow("Alias") {
                VStack(alignment: .leading, spacing: 2) {
                    TextField(
                        "Optional display name, e.g. \u{201C}Fast drafts\u{201D}",
                        text: $model.draftModelAlias)
                    Text("Shown in Rafu instead of the model ID. Never sent to the provider.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
            if model.draftKind == .openAI || model.draftKind == .openAICompatible {
                fieldRow("API") {
                    Picker("API", selection: $model.draftTransport) {
                        ForEach(OpenAICompatibleTransport.allCases) { transport in
                            Text(transport.title).tag(transport)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            fieldRow("API Key") {
                HStack {
                    SecureField(
                        model.hasStoredAPIKey ? "Stored in Keychain" : "Required",
                        text: $model.apiKey
                    )
                    if model.hasStoredAPIKey {
                        Button("Remove API Key") { model.beginRemoveAPIKey() }
                            .buttonStyle(.link)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private func actionRow(model: AIProviderSettingsModel) -> some View {
        HStack {
            statusView(model.status)
            Spacer()
            Button("Test Connection") { model.beginTest() }
            if hasChanges(model: model) {
                Button("Save") { model.beginSave() }
                    .buttonStyle(RafuProminentButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Save") { model.beginSave() }
            }
        }
    }

    /// A provider that was added but never saved also counts as changed, so
    /// Save is the default action until it has been written once.
    private func hasChanges(model: AIProviderSettingsModel) -> Bool {
        guard let id = model.selectedID else { return false }
        guard model.persistedIDs.contains(id),
            let saved = model.configurations.first(where: { $0.id == id })
        else { return true }
        return AIProviderDraftChange.hasChanges(
            saved: saved,
            name: model.draftName,
            kind: model.draftKind,
            baseURL: model.draftBaseURL,
            model: model.draftModel,
            modelAlias: model.draftModelAlias,
            transport: model.draftTransport,
            maxOutputTokens: model.draftMaxOutputTokens,
            enteredAPIKey: model.apiKey)
    }

    @ViewBuilder
    private func statusView(_ status: AIProviderSettingsModel.Status) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .working(let message):
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(message).foregroundStyle(.secondary)
            }
        case .success(let message):
            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failure(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }

    /// Right-aligned label column, left-aligned controls.
    private func fieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
