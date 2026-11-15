import SwiftUI

/// Settings ▸ General ▸ Notch: whether the notch companion exists, whether it
/// shows the mascot, how it opens, what it does on a Mac without a notch, and
/// which sections its panel offers. Every control writes `UserDefaults`
/// through `@AppStorage` (the same keys `NotchDisplayPreferenceStore` reads)
/// and then asks the companion model to reload and reposition.
struct NotchSettingsSection: View {
    @AppStorage(NotchCompanionPreferenceStore.defaultsKey) private var companionEnabled = true
    @AppStorage(NotchDisplayPreferenceStore.mascotKey) private var mascotEnabled = true
    @AppStorage(NotchDisplayPreferenceStore.openOnHoverKey) private var opensOnHover = true
    @AppStorage(NotchDisplayPreferenceStore.plainDisplayPillKey) private var pillOnPlainDisplays =
        false
    @AppStorage(NotchDisplayPreferenceStore.systemNowPlayingKey) private var systemNowPlaying =
        true
    @AppStorage(NotchDisplayPreferenceStore.usageGlancePositionKey)
    private var usageGlancePosition: UsageGlancePosition = .belowIsland

    /// This Mac has a system Dynamic Island: the companion shows Usage only,
    /// below the island or in the menu bar, and hover never opens it.
    private var isIsland: Bool { NotchCompanionModel.shared.surface == .island }

    private var footerText: String {
        let base =
            "Choose the sections the notch panel offers. Agents stays on if you turn every section off. Now Playing reads system media through the bundled adapter; with that off, it reads Music and Spotify only and asks macOS for permission the first time you connect it."
        guard isIsland else { return base }
        return base
            + " On a Mac with a Dynamic Island, the companion is a small pill below the island or an item in the menu bar. The pill opens usage details only. The menu bar item opens a card with Agents, Up next, and Usage, and shows how many agents need you."
    }

    var body: some View {
        Section {
            Toggle("Show notch companion", isOn: $companionEnabled)
                .help(
                    "A strip hugging the notch on notched Macs, with the Rafu mascot and a panel of your Ensembles, agents, Now Playing, and usage. On a Mac without a notch it appears only if you turn on the floating pill below; the attention HUD still appears on demand when a terminal session needs you."
                )
            Toggle("Show the Rafu mascot", isOn: $mascotEnabled)
                .help(
                    "The mascot reacts to your agents: running, needs you, reply ready. Off shows the plain Rafu mark."
                )
                .disabled(!companionEnabled)
            Toggle("Open when the pointer rests on the notch", isOn: $opensOnHover)
                .help(
                    "Off: resting the pointer on the notch only widens the strip, and a click opens the panel."
                )
                .disabled(!companionEnabled || isIsland)
            Toggle("Show a floating pill on displays without a notch", isOn: $pillOnPlainDisplays)
                .help(
                    "Adds a small pill at the top centre, under the menu bar, on the built-in display of a Mac that has no notch."
                )
                .disabled(!companionEnabled)
            if isIsland {
                Picker("Usage glance", selection: $usageGlancePosition) {
                    ForEach(UsageGlancePosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .help(
                    "Where this Mac shows your agent usage: a small pill below the Dynamic Island, or an item with the other icons on the right of the menu bar."
                )
                .disabled(!companionEnabled)
            }
            ForEach(NotchSection.allCases) { section in
                NotchSectionToggle(section: section)
                    .disabled(!companionEnabled)
            }
            Toggle("Now Playing: read what any app plays", isOn: $systemNowPlaying)
                .help(
                    "Uses the bundled MediaRemote adapter, as Cider does, to show what any app plays (browsers and video too) without an Automation prompt. It relies on a private macOS framework. Off, or when the adapter is missing or stops, Rafu asks Music and Spotify instead."
                )
                .disabled(!companionEnabled)
        } header: {
            Text("Notch")
        } footer: {
            Text(footerText)
        }
        .onChange(of: systemNowPlaying) { _, _ in
            NotchCompanionModel.shared.nowPlaying.sourcePreferenceDidChange()
        }
        .onChange(of: companionEnabled) { _, _ in
            NotchCompanionModel.shared.displayPreferencesDidChange()
        }
        .onChange(of: mascotEnabled) { _, _ in
            NotchCompanionModel.shared.displayPreferencesDidChange()
        }
        .onChange(of: opensOnHover) { _, _ in
            NotchCompanionModel.shared.displayPreferencesDidChange()
        }
        .onChange(of: pillOnPlainDisplays) { _, _ in
            NotchCompanionModel.shared.displayPreferencesDidChange()
        }
        .onChange(of: usageGlancePosition) { _, _ in
            NotchCompanionModel.shared.displayPreferencesDidChange()
        }
    }
}

/// One section's on/off switch, keyed by the section's own defaults key.
private struct NotchSectionToggle: View {
    let section: NotchSection
    @AppStorage private var isOn: Bool

    init(section: NotchSection) {
        self.section = section
        _isOn = AppStorage(wrappedValue: true, section.defaultsKey)
    }

    var body: some View {
        Toggle("Panel: " + section.title, isOn: $isOn)
            .help(section.summary)
            .onChange(of: isOn) { _, _ in
                NotchCompanionModel.shared.displayPreferencesDidChange()
            }
    }
}
