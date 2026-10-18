import Foundation
import RafuCore
import Testing

@testable import RafuApp

/// Pure presentation rules behind the redesigned Settings panes (S4–S8).
@Suite("Settings pane presentation rules")
struct SettingsPanePresentationTests {
    // MARK: S4 AI

    private func saved() -> AIProviderConfiguration {
        AIProviderConfiguration(
            name: "OpenAI", kind: .openAI, model: "gpt-5.1", modelAlias: "Fast drafts",
            openAITransport: .responses, maxOutputTokens: 256)
    }

    private func hasChanges(
        _ configuration: AIProviderConfiguration,
        name: String? = nil,
        model: String? = nil,
        alias: String? = nil,
        apiKey: String = ""
    ) -> Bool {
        AIProviderDraftChange.hasChanges(
            saved: configuration,
            name: name ?? configuration.name,
            kind: configuration.kind,
            baseURL: configuration.baseURL.absoluteString,
            model: model ?? configuration.model,
            modelAlias: alias ?? (configuration.modelAlias ?? ""),
            transport: configuration.openAITransport,
            maxOutputTokens: configuration.maxOutputTokens,
            enteredAPIKey: apiKey)
    }

    @Test("A form equal to the saved provider has no changes, whitespace aside")
    func unchangedDraft() {
        let configuration = saved()
        #expect(!hasChanges(configuration))
        #expect(!hasChanges(configuration, name: "  OpenAI \n", model: " gpt-5.1 "))
    }

    @Test("Editing any field, or typing an API key, counts as a change")
    func editedDraft() {
        let configuration = saved()
        #expect(hasChanges(configuration, name: "Work OpenAI"))
        #expect(hasChanges(configuration, model: "gpt-5.2"))
        #expect(hasChanges(configuration, alias: ""))
        #expect(hasChanges(configuration, apiKey: "sk-test"))
        #expect(!hasChanges(configuration, apiKey: "   "))
    }

    // MARK: S5 Language servers

    @Test("Table height fits the rows up to a cap")
    func languageServerTableHeight() {
        let presentation = LanguageServerTablePresentation.self
        #expect(
            presentation.tableHeight(rowCount: 0)
                == presentation.headerHeight + presentation.rowHeight)
        #expect(
            presentation.tableHeight(rowCount: 3)
                == presentation.headerHeight + 3 * presentation.rowHeight)
        #expect(presentation.tableHeight(rowCount: 500) == presentation.maximumHeight)
    }

    @Test("Server status words are short and never empty")
    func languageServerStatusText() {
        #expect(LanguageServerTablePresentation.statusText(.notInstalled) == "Not installed")
        #expect(
            LanguageServerTablePresentation.statusText(.installed(version: "1.2.3"))
                == "Installed · 1.2.3")
        #expect(LanguageServerTablePresentation.sizeText(nil) == "—")
    }

    // MARK: S6 Usage

    @Test("Dragging reorders the displayed providers and keeps hidden ones in place")
    func stripReorderKeepsDisabledInPlace() {
        // `b` is disabled: it is in the full order but not displayed.
        let full = ["a", "b", "c", "d"]
        let displayed = ["a", "c", "d"]
        let moved = UsageSettingsPresentation.reordered(
            full: full, displayed: displayed, fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(moved == ["d", "b", "a", "c"])

        let down = UsageSettingsPresentation.reordered(
            full: full, displayed: displayed, fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(down == ["c", "b", "d", "a"])

        let noop = UsageSettingsPresentation.reordered(
            full: full, displayed: displayed, fromOffsets: IndexSet(integer: 1), toOffset: 1)
        #expect(noop == full)
    }

    @MainActor
    @Test("UsageSettingsModel applies a List.onMove drag and persists the order")
    func modelAppliesDrag() throws {
        let suite = "SettingsPaneTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let stripStore = UsageStripOrderStore(suiteName: suite)
        stripStore.setOrder([.claude, .codex, .cursor])
        let model = UsageSettingsModel(
            descriptors: [
                ClaudeProvider.descriptor, CodexProvider.descriptor, CursorProvider.descriptor,
            ],
            enableStore: UsageEnableStore(suiteName: suite),
            stripOrderStore: stripStore)
        model.setEnabled(true, for: .claude)
        model.setEnabled(true, for: .codex)
        model.setEnabled(true, for: .cursor)

        model.moveStripProviders(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(model.stripOrderedEnabledRows().map(\.id) == [.cursor, .claude, .codex])
        #expect(stripStore.order() == [.cursor, .claude, .codex])
    }

    @Test("The privacy text stays inline until the first Connect, then folds away")
    func disclosureVisibility() {
        let presentation = UsageSettingsPresentation.self
        func inline(
            _ pattern: UsageAuthPattern, enabled: Bool = true, connected: Bool = false,
            key: Bool = false, session: Bool = false
        ) -> Bool {
            presentation.showsDisclosureInline(
                authPattern: pattern, isEnabled: enabled, isConnected: connected,
                hasStoredKey: key, hasImportedSession: session)
        }
        #expect(inline(.piggybackNetwork))
        #expect(!inline(.piggybackNetwork, connected: true))
        #expect(inline(.localSessionPiggyback))
        #expect(!inline(.localSessionPiggyback, connected: true))
        #expect(inline(.apiKey))
        #expect(!inline(.apiKey, key: true))
        #expect(inline(.cookieImport))
        #expect(!inline(.cookieImport, session: true))
        #expect(inline(.localZeroConfig, enabled: false))
        #expect(!inline(.localZeroConfig, enabled: true))
        #expect(inline(.unavailable))
    }

    @MainActor
    @Test("The status capsule uses words for every connection state")
    func statusCapsuleWords() {
        let presentation = UsageSettingsPresentation.self
        func label(
            _ pattern: UsageAuthPattern, enabled: Bool = true,
            connection: UsageSettingsModel.ConnectionState = .disconnected,
            key: Bool = false, session: Bool = false
        ) -> String {
            presentation.statusLabel(
                authPattern: pattern, isEnabled: enabled, connection: connection,
                hasStoredKey: key, hasImportedSession: session)
        }
        #expect(label(.piggybackNetwork, connection: .connected) == "Connected")
        #expect(label(.piggybackNetwork, connection: .connecting) == "Connecting…")
        #expect(label(.piggybackNetwork, connection: .disconnected) == "Not connected")
        #expect(label(.piggybackNetwork, enabled: false) == "Off")
        #expect(label(.apiKey, key: true) == "Key stored")
        #expect(label(.apiKey) == "No key")
        #expect(label(.cookieImport, session: true) == "Session imported")
        #expect(label(.localZeroConfig) == "Local")
        #expect(label(.unavailable) == "Unavailable")
    }

    // MARK: S7 Agents

    @Test("Sign-in state is a glyph plus a word")
    func signInPresentation() {
        let installed = AdapterProbe(
            installed: true, executableURL: URL(fileURLWithPath: "/usr/local/bin/x"),
            version: "1.0")
        func make(_ probe: AdapterProbe?, _ auth: AdapterAuthStatus?) -> ConductorSignInPresentation
        {
            ConductorSignInPresentation.make(probe: probe, auth: auth)
        }
        #expect(make(nil, nil).word == "Checking…")
        #expect(make(.notInstalled, nil).word == "Not installed")
        #expect(make(installed, .authenticated).word == "Signed in")
        #expect(make(installed, .authenticated).systemImage == "checkmark.circle")
        #expect(make(installed, .notAuthenticated(hint: "run login")).word == "Sign-in needed")
        #expect(make(installed, .unknown()).word == "Unknown")
        #expect(make(installed, nil).word == "Unknown")
        let words = [
            make(installed, .authenticated), make(installed, .notAuthenticated(hint: "")),
            make(installed, .unknown()),
        ]
        #expect(Set(words.map(\.systemImage)).count == 3)
    }

    @Test("The home directory is abbreviated to a tilde, but only as a whole component")
    func pathAbbreviation() {
        let display = ConductorAgentDisplay.self
        #expect(
            display.abbreviated("/Users/me/.local/bin/claude", home: "/Users/me")
                == "~/.local/bin/claude")
        #expect(display.abbreviated("/Users/me", home: "/Users/me/") == "~")
        #expect(
            display.abbreviated("/Users/mentor/bin/x", home: "/Users/me") == "/Users/mentor/bin/x")
        #expect(
            display.abbreviated("/opt/homebrew/bin/codex", home: "/Users/me")
                == "/opt/homebrew/bin/codex")
        #expect(display.abbreviated("/x", home: "/") == "/x")
    }

    @Test("The version cell shows a dash until a CLI is found")
    func versionCell() {
        let found = AdapterProbe(installed: true, executableURL: nil, version: "2.1.302")
        let noVersion = AdapterProbe(installed: true, executableURL: nil, version: nil)
        #expect(ConductorAgentDisplay.versionText(nil) == "—")
        #expect(ConductorAgentDisplay.versionText(.notInstalled) == "—")
        #expect(ConductorAgentDisplay.versionText(found) == "2.1.302")
        #expect(ConductorAgentDisplay.versionText(noVersion) == "Unknown")
    }

    // MARK: S8 Ensemble

    @Test("Agent skill copy uses plain words")
    func ensembleSkillCopy() {
        #expect(EnsembleSkillCopy.summary.contains("Claude Code and Codex"))
        #expect(!EnsembleSkillCopy.footer.contains("Verb"))
    }
}
