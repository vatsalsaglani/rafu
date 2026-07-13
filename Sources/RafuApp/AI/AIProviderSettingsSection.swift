import SwiftUI

struct AIProviderSettingsSection: View {
    @State private var model: AIProviderSettingsModel

    init(model: AIProviderSettingsModel = AIProviderSettingsModel()) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model

        Section {
            VStack(alignment: .leading, spacing: 14) {
                providerToolbar(model: model)
                Divider()
                providerFields(model: model)
                actionRow(model: model)
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

    private func providerToolbar(model: AIProviderSettingsModel) -> some View {
        HStack {
            Picker(
                "Provider",
                selection: Binding(
                    get: { model.selectedID },
                    set: { id in
                        guard let id else { return }
                        model.beginSelect(id)
                    }
                )
            ) {
                ForEach(model.configurations) { configuration in
                    Text("\(configuration.name) · \(configuration.displayModelName)")
                        .tag(Optional(configuration.id))
                }
            }

            Menu("Add Provider", systemImage: "plus") {
                ForEach(AIProviderKind.allCases) { kind in
                    Button(kind.title) { model.add(kind) }
                }
            }
            .labelStyle(.iconOnly)
            .help("Add provider")

            Button("Delete Provider", systemImage: "trash", role: .destructive) {
                model.beginDelete()
            }
            .labelStyle(.iconOnly)
            .help("Delete selected provider")
        }
    }

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

    private func actionRow(model: AIProviderSettingsModel) -> some View {
        HStack {
            statusView(model.status)
            Spacer()
            Button("Test Connection") { model.beginTest() }
            Button("Save") { model.beginSave() }
                .buttonStyle(.borderedProminent)
        }
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

    private func fieldRow<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
