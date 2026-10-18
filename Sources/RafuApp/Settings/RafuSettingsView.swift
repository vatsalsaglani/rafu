import RafuCore
import SwiftUI

/// The body of the standard `Settings` scene (`RafuApplication`). `TabView`
/// with `.tabItem` gives macOS's native toolbar-style panes; each pane is a
/// grouped `Form`. This is the only way a user reaches Settings: ⌘, and every
/// "Settings…" entry point open this one window.
struct RafuSettingsView: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @AppStorage("terminalAttentionSurface") private var terminalAttentionSurface =
        TerminalAttentionSurface.both.rawValue
    @AppStorage(RafuHaptics.canvasHapticsDefaultsKey) private var canvasHapticsEnabled = true
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: SettingsPane = .general
    /// Panes are built on first visit and then kept alive. Building every pane
    /// eagerly would perform each pane's task-driven load when Settings first
    /// opens, and rebuilding on revisit would repeat it.
    @State private var visitedPanes: Set<SettingsPane> = [.general]

    var body: some View {
        TabView(selection: $pane) {
            ForEach(SettingsPane.allCases) { candidate in
                paneHost(candidate)
                    .tabItem {
                        Label(candidate.title, systemImage: candidate.systemImage)
                    }
                    .tag(candidate)
            }
        }
        .frame(width: SettingsPresentationLayout.windowWidth)
        .frame(
            minHeight: SettingsPresentationLayout.minimumPaneHeight,
            idealHeight: SettingsPresentationLayout.idealPaneHeight,
            maxHeight: SettingsPresentationLayout.maximumPaneHeight
        )
        .rafuTheme(activeTheme)
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: pane) { _, newPane in visitedPanes.insert(newPane) }
    }

    @ViewBuilder
    private func paneHost(_ candidate: SettingsPane) -> some View {
        if visitedPanes.contains(candidate) {
            form(for: candidate)
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func form(for pane: SettingsPane) -> some View {
        Form {
            switch pane {
            case .general:
                generalSections
            case .appearance:
                ThemeSettingsSection()
                AIThemeGeneratorSection()
            case .ai:
                AIProviderSettingsSection()
            case .languageServers:
                LanguageServersSettingsSection()
            case .usage:
                UsageSettingsSection()
            case .agents:
                ConductorSettingsSection()
                AgentHistorySettingsSection()
            case .ensemble:
                EnsembleSettingsSection()
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var generalSections: some View {
        Section {
            HStack(spacing: RafuMetrics.space4) {
                RafuBrandMarkView().frame(width: 48, height: 48)
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
            .accessibilityElement(children: .combine)
            LabeledContent("Version", value: RafuBuildInformation.version)
            LabeledContent(
                "Command Line Tool",
                value: "Bundled as \(RafuBuildInformation.cliName)"
            )
        }

        Section("Workspace") {
            Toggle("Show process memory in status bar", isOn: $showsProcessMemory)

            LabeledContent("Terminal attention") {
                Picker("Terminal attention", selection: $terminalAttentionSurface) {
                    ForEach(TerminalAttentionSurface.allCases, id: \.rawValue) { surface in
                        Text(surface.displayName).tag(surface.rawValue)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .frame(
                    minWidth: SettingsPresentationLayout.minimumPopupWidth,
                    alignment: .trailing
                )
            }
            .help(
                "Where to surface a background terminal session that bells (e.g. an agent CLI finishing or needing input): a system notification, a HUD below the notch, both, or neither. Replies you type are sent to that terminal. macOS will ask to allow notifications the first time a notification would post."
            )
        }

        NotchSettingsSection()

        Section {
            Toggle("Haptic feedback on the Canvas", isOn: $canvasHapticsEnabled)
        } header: {
            Text("Canvas")
        } footer: {
            Text("Plays only on Force Touch trackpads.")
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
