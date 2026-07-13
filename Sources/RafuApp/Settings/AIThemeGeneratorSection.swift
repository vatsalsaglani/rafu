import AppKit
import SwiftUI

/// Appearance-settings section that turns a plain-language description into a
/// Rafu theme: copy a ready-made prompt for any chatbot, or generate directly
/// through the configured AI provider and import the validated result.
struct AIThemeGeneratorSection: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @State private var descriptionText = ""
    @State private var isGenerating = false
    @State private var statusMessage: String?
    @State private var didCopy = false
    @State private var generationTask: Task<Void, Never>?

    private let themeService = ThemeFileService()
    private let configurationStore = UserDefaultsAIProviderConfigurationStore()
    private let secretStore = KeychainAISecretStore()
    private let client = AIProviderClient()

    var body: some View {
        Section {
            TextField(
                "Describe the look you want",
                text: $descriptionText,
                prompt: Text("e.g. Warm paper tones with forest-green accents, easy on the eyes"),
                axis: .vertical
            )
            .lineLimit(2...4)

            HStack(spacing: 10) {
                Button(
                    didCopy ? "Copied" : "Copy Prompt",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc"
                ) {
                    copyPrompt()
                }
                .help(
                    "Copies a complete prompt for ChatGPT, Claude, or any assistant. Import the JSON it returns."
                )

                Button("Generate with AI", systemImage: "sparkles") {
                    generate()
                }
                .disabled(isGenerating)
                .help(
                    "Uses your configured commit-message provider to design and install the theme.")

                if isGenerating {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { generationTask?.cancel() }
                }
                Spacer()
            }

            if let statusMessage {
                Label(statusMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Design a Theme with AI")
        } footer: {
            Text(
                "Generate uses the provider configured under Settings → AI and sends only your "
                    + "description. The result is validated and saved to your theme folder."
            )
        }
        .onDisappear { generationTask?.cancel() }
    }

    private func copyPrompt() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            AIThemePrompt.clipboardPrompt(description: descriptionText),
            forType: .string
        )
        didCopy = true
        statusMessage = "Prompt copied. Paste it into any assistant, then import the JSON here."
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }

    private func generate() {
        generationTask?.cancel()
        isGenerating = true
        statusMessage = "Asking your configured provider…"
        let description = descriptionText
        generationTask = Task {
            defer { isGenerating = false }
            do {
                let configurations = try await configurationStore.load()
                let selectedID = await configurationStore.selectedConfigurationID()
                guard
                    let configuration = configurations.first(where: { $0.id == selectedID })
                        ?? configurations.first
                else {
                    statusMessage = "No AI provider configured. Add one under Settings → AI."
                    return
                }
                guard let apiKey = try await secretStore.secret(for: configuration.id),
                    !apiKey.isEmpty
                else {
                    statusMessage =
                        "No API key stored for \(configuration.name). Save one under Settings → AI."
                    return
                }
                var generousConfiguration = configuration
                generousConfiguration.maxOutputTokens =
                    AIProviderConfiguration.allowedOutputTokenRange.upperBound
                let stream = try client.makeTextStream(
                    configuration: generousConfiguration,
                    apiKey: apiKey,
                    instructions: AIThemePrompt.instruction,
                    prompt: AIThemePrompt.userPrompt(description: description)
                )
                var response = ""
                for try await chunk in stream {
                    try Task.checkCancellation()
                    response += chunk
                }
                guard let data = AIThemePrompt.extractJSON(from: response) else {
                    statusMessage = "The provider did not return valid theme JSON. Try again."
                    return
                }
                let descriptor = try await themeService.importThemeData(data)
                themeChoice = descriptor.id
                themeRevision &+= 1
                statusMessage = "Installed and applied “\(descriptor.name)”."
            } catch is CancellationError {
                statusMessage = "Generation cancelled."
            } catch {
                statusMessage = error.localizedDescription
            }
        }
    }
}
