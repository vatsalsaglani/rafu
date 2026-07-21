import RafuCore
import SwiftUI

struct RafuSettingsView: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @AppStorage("showsProcessMemory") private var showsProcessMemory = false
    @AppStorage("terminalBellNotificationsEnabled") private var terminalBellNotificationsEnabled =
        true
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                Form {
                    Section {
                        HStack(spacing: 16) {
                            RafuBrandMarkView().frame(width: 58, height: 58)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(alignment: .firstTextBaseline) {
                                    Text("Rafu").font(.title2.weight(.semibold))
                                    Text("રફૂ").font(.title3).foregroundStyle(.secondary)
                                }
                                Text("Focused repository mending, native to macOS.")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        LabeledContent("Version", value: RafuBuildInformation.version)
                        LabeledContent("Command Line Tool", value: "Bundled as rafu")
                        Toggle("Show process memory in status bar", isOn: $showsProcessMemory)
                        Toggle(
                            "Notify when a terminal needs attention",
                            isOn: $terminalBellNotificationsEnabled
                        )
                        .help(
                            "Posts a system notification when a background terminal session bells (e.g. an agent CLI finishing or needing input). macOS will ask to allow notifications the first time this happens."
                        )
                    }
                }
                .formStyle(.grouped)
            }

            Tab("Appearance", systemImage: "paintpalette") {
                Form {
                    ThemeSettingsSection()
                    AIThemeGeneratorSection()
                }
                .formStyle(.grouped)
            }

            Tab("AI", systemImage: "sparkles") {
                Form {
                    AIProviderSettingsSection()
                }
                .formStyle(.grouped)
            }

            Tab("Language Servers", systemImage: "server.rack") {
                Form {
                    LanguageServersSettingsSection()
                }
                .formStyle(.grouped)
            }
        }
        .environment(\.rafuTheme, activeTheme)
        .preferredColorScheme(preferredColorScheme)
        .scenePadding()
        .frame(width: 760, height: 620)
    }

    private var activeTheme: RafuTheme {
        _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }
    private var preferredColorScheme: ColorScheme? {
        themeChoice == RafuThemeChoice.system.rawValue ? nil : activeTheme.colorScheme
    }
}
