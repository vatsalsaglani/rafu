import RafuCore
import SwiftUI

/// The shared Settings body for both the editor-hosted canvas and the native
/// fallback scene. Navigation adapts to the canvas that hosts this view; it
/// never consults window size or recreates an already-visited pane.
struct RafuSettingsView: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @AppStorage("terminalAttentionSurface") private var terminalAttentionSurface =
        TerminalAttentionSurface.both.rawValue
    @AppStorage(NotchCompanionPreferenceStore.defaultsKey) private var notchCompanionEnabled = true
    @Environment(\.colorScheme) private var systemScheme

    @State private var pane: SettingsPane = .general
    /// Panes are built on first visit and then kept alive. A plain `switch`
    /// would repeat each pane's task-driven load on revisit, while eagerly
    /// building every pane would perform its I/O when Settings first opens.
    @State private var visitedPanes: Set<SettingsPane> = [.general]

    var body: some View {
        GeometryReader { geometry in
            adaptiveSettingsLayout(
                isCompact: SettingsPresentationLayout.usesCompactNavigation(
                    forAvailableCanvasWidth: geometry.size.width
                )
            )
        }
        .rafuTheme(activeTheme)
        .preferredColorScheme(preferredColorScheme)
        .onChange(of: pane) { _, newPane in visitedPanes.insert(newPane) }
    }

    @ViewBuilder
    private func adaptiveSettingsLayout(isCompact: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(
                alignment: .top,
                spacing: isCompact ? 0 : SettingsPresentationLayout.navigationPageGap
            ) {
                if !isCompact {
                    SettingsPaneNavigation(selection: $pane, variant: .regular)
                }
                pageColumn(isCompact: isCompact)
            }
            .frame(
                maxWidth: isCompact
                    ? SettingsPresentationLayout.pageMaximumWidth
                    : SettingsPresentationLayout.regularCombinedMaximumWidth
                        - (SettingsPresentationLayout.outerPadding * 2),
                maxHeight: .infinity,
                alignment: .topLeading
            )
        }
        .padding(SettingsPresentationLayout.outerPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func pageColumn(isCompact: Bool) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            pageIdentity(isCompact: isCompact)
            paneContent
        }
        .frame(
            maxWidth: SettingsPresentationLayout.pageMaximumWidth,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    /// Compact category navigation belongs to the page hierarchy. The retained
    /// pane host stays below this identity block, outside the layout variant,
    /// so resizing never recreates visited panes or restarts their work.
    @ViewBuilder
    private func pageIdentity(isCompact: Bool) -> some View {
        if isCompact {
            VStack(alignment: .leading, spacing: SettingsPresentationLayout.navigationPageGap) {
                SettingsPaneNavigation(selection: $pane, variant: .compact)
                SettingsPageHeader(pane: pane)
            }
        } else {
            SettingsPageHeader(pane: pane)
        }
    }

    /// This is intentionally one retained ZStack host outside the navigation
    /// variant branch. Changing widths therefore changes only navigation
    /// placement, not pane identity, tasks, scrolling, or focus ownership.
    private var paneContent: some View {
        ZStack {
            ForEach(SettingsPane.allCases.filter(visitedPanes.contains)) { candidate in
                form(for: candidate)
                    .opacity(candidate == pane ? 1 : 0)
                    .disabled(candidate != pane)
                    .accessibilityHidden(candidate != pane)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private func form(for pane: SettingsPane) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch pane {
                case .general:
                    generalSection
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
                case .ensemble:
                    EnsembleSettingsSection()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, RafuMetrics.space4)
        }
        .scrollIndicators(.automatic)
    }

    private var generalSection: some View {
        RafuSettingsSection {
            Text("Rafu")
        } content: {
            VStack(alignment: .leading, spacing: 0) {
                RafuSettingsRow {
                    HStack(spacing: RafuMetrics.space4) {
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
                }
                settingsDivider
                RafuSettingsRow {
                    LabeledContent("Version", value: RafuBuildInformation.version)
                }
                settingsDivider
                RafuSettingsRow {
                    LabeledContent(
                        "Command Line Tool",
                        value: "Bundled as \(RafuBuildInformation.cliName)"
                    )
                }
                settingsDivider
                RafuSettingsRow {
                    Toggle("Show process memory in status bar", isOn: $showsProcessMemory)
                }
                settingsDivider
                RafuSettingsRow {
                    Picker("Terminal attention", selection: $terminalAttentionSurface) {
                        ForEach(TerminalAttentionSurface.allCases, id: \.rawValue) { surface in
                            Text(surface.displayName).tag(surface.rawValue)
                        }
                    }
                    .help(
                        "Where to surface a background terminal session that bells (e.g. an agent CLI finishing or needing input): a system notification, a HUD below the notch, both, or neither. Replies you type are sent to that terminal. macOS will ask to allow notifications the first time a notification would post."
                    )
                }
                settingsDivider
                RafuSettingsRow {
                    Toggle("Show notch companion", isOn: $notchCompanionEnabled)
                        .help(
                            "A persistent strip hugging the notch on notched Macs, showing your open editor windows and whether any agent needs attention. Displays without a notch never show this strip; the attention HUD still appears there on demand when a terminal session needs you."
                        )
                        .onChange(of: notchCompanionEnabled) { _, _ in
                            NotchCompanionModel.shared.activateIfEnabled()
                        }
                }
            }
        }
    }

    private var settingsDivider: some View {
        Divider().overlay(activeTheme.palette.borderSubtle)
    }

    private var activeTheme: RafuTheme {
        _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }

    private var preferredColorScheme: ColorScheme? {
        themeChoice == RafuThemeChoice.system.rawValue ? nil : activeTheme.colorScheme
    }
}

private struct SettingsPageHeader: View {
    let pane: SettingsPane

    @Environment(\.rafuTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: RafuMetrics.space1) {
            Text(pane.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(theme.palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(pane.subtitle)
                .font(.callout)
                .foregroundStyle(theme.palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
