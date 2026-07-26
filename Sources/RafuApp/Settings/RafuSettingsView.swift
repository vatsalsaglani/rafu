import RafuCore
import SwiftUI

struct RafuSettingsView: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @AppStorage("terminalAttentionSurface") private var terminalAttentionSurface =
        TerminalAttentionSurface.both.rawValue
    @AppStorage(NotchCompanionPreferenceStore.defaultsKey) private var notchCompanionEnabled = true
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: SettingsPane = .general
    /// Panes are built on first visit and then kept alive, which is what the
    /// tab view this replaced did: its tab contents were created lazily and
    /// retained, so a pane's `.task`-driven load ran once per Settings
    /// session. A plain `switch` would tear each pane down on the way out and
    /// re-run that load on every revisit — a visible behavior change (usage
    /// figures, catalogs and CLI detection would re-spin) — while an eager
    /// `ForEach` over all seven would do the opposite and fire every pane's
    /// I/O the moment Settings opens.
    @State private var visitedPanes: Set<SettingsPane> = [.general]

    var body: some View {
        VStack(spacing: 0) {
            SettingsPaneStrip(selection: $pane)
            Divider().overlay(activeTheme.palette.borderSubtle)
            paneContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .rafuTheme(activeTheme)
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: pane) { _, newPane in visitedPanes.insert(newPane) }
    }

    private var paneContent: some View {
        ZStack {
            ForEach(SettingsPane.allCases.filter(visitedPanes.contains)) { candidate in
                form(for: candidate)
                    .opacity(candidate == pane ? 1 : 0)
                    // A retained-but-hidden pane must leave the keyboard and
                    // VoiceOver alike: `.opacity(0)` alone keeps its controls
                    // focusable under Full Keyboard Access.
                    .disabled(candidate != pane)
                    .accessibilityHidden(candidate != pane)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func form(for pane: SettingsPane) -> some View {
        switch pane {
        case .general:
            Form { generalSection }.formStyle(.grouped)
        case .appearance:
            Form {
                ThemeSettingsSection()
                AIThemeGeneratorSection()
            }
            .formStyle(.grouped)
        case .ai:
            Form { AIProviderSettingsSection() }.formStyle(.grouped)
        case .languageServers:
            Form { LanguageServersSettingsSection() }.formStyle(.grouped)
        case .usage:
            Form { UsageSettingsSection() }.formStyle(.grouped)
        case .agents:
            Form { ConductorSettingsSection() }.formStyle(.grouped)
        case .ensemble:
            Form { EnsembleSettingsSection() }.formStyle(.grouped)
        }
    }

    @ViewBuilder
    private var generalSection: some View {
        Section {
            HStack(spacing: 16) {
                RafuBrandMarkView().frame(width: 58, height: 58)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(RafuBuildInformation.appName)
                            .font(.title2.weight(.semibold))
                        Text("રફૂ").font(.title3).foregroundStyle(.secondary)
                    }
                    Text("Focused repository mending, native to macOS.")
                        .foregroundStyle(.secondary)
                }
            }
            LabeledContent("Version", value: RafuBuildInformation.version)
            LabeledContent(
                "Command Line Tool",
                value: "Bundled as \(RafuBuildInformation.cliName)"
            )
            Toggle("Show process memory in status bar", isOn: $showsProcessMemory)
            Picker("Terminal attention", selection: $terminalAttentionSurface) {
                ForEach(TerminalAttentionSurface.allCases, id: \.rawValue) { surface in
                    Text(surface.displayName).tag(surface.rawValue)
                }
            }
            .help(
                "Where to surface a background terminal session that bells (e.g. an agent CLI finishing or needing input): a system notification, a HUD below the notch, both, or neither. Replies you type are sent to that terminal. macOS will ask to allow notifications the first time a notification would post."
            )
            Toggle("Show notch companion", isOn: $notchCompanionEnabled)
                .help(
                    "A persistent strip hugging the notch on notched Macs, showing your open editor windows and whether any agent needs attention. Displays without a notch never show this strip; the attention HUD still appears there on demand when a terminal session needs you."
                )
                .onChange(of: notchCompanionEnabled) { _, _ in
                    NotchCompanionModel.shared.activateIfEnabled()
                }
        }
    }

    private var activeTheme: RafuTheme {
        _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }
    private var preferredColorScheme: ColorScheme? {
        themeChoice == RafuThemeChoice.system.rawValue ? nil : activeTheme.colorScheme
    }
}
