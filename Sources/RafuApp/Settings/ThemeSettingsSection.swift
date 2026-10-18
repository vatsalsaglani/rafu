import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings > Appearance: Follow System with a light/dark theme pair, or one
/// fixed theme; theme cards that act as radio buttons; and theme file
/// commands as labelled buttons. The persistence rules live in
/// `ThemeAppearancePreference` (pure, tested).
struct ThemeSettingsSection: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage(ThemeAppearancePreference.lightChoiceKey) private var lightChoice =
        ThemeAppearancePreference.defaultLightIdentifier
    @AppStorage(ThemeAppearancePreference.darkChoiceKey) private var darkChoice =
        ThemeAppearancePreference.defaultDarkIdentifier
    @AppStorage("themeRevision") private var themeRevision = 0
    @Environment(\.colorScheme) private var systemScheme
    @State private var userThemes: [UserThemeDescriptor] = []
    @State private var customOptions: [ThemeOption] = []
    @State private var isImporting = false
    @State private var isCreating = false
    @State private var newThemeName = "My Rafu Theme"
    @State private var statusMessage: String?

    private let service = ThemeFileService()

    var body: some View {
        Group {
            Section("Theme") {
                Toggle("Follow System Appearance", isOn: followsSystemBinding)
                if selection.followsSystem {
                    LabeledContent("Light appearance") {
                        themePicker(
                            "Light appearance",
                            options: options.filter { !$0.isDark },
                            selection: pairBinding(isDark: false))
                    }
                    LabeledContent("Dark appearance") {
                        themePicker(
                            "Dark appearance",
                            options: options.filter(\.isDark),
                            selection: pairBinding(isDark: true))
                    }
                } else {
                    LabeledContent("Theme") {
                        themePicker(
                            "Theme", options: options, selection: fixedBinding)
                    }
                }
            }

            Section {
                LazyVGrid(columns: [.init(.adaptive(minimum: 142), spacing: 10)], spacing: 10) {
                    ForEach(options) { option in
                        Button {
                            choose(option)
                        } label: {
                            ThemeSettingsCard(
                                theme: option.theme,
                                selected: selection.isActive(option.id),
                                badge: badge(for: option)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Use \(option.name) theme")
                        .accessibilityValue(
                            selection.isActive(option.id) ? "Selected" : "Not selected"
                        )
                        .accessibilityAddTraits(
                            selection.isActive(option.id) ? .isSelected : []
                        )
                        .help("Use \(option.name) theme")
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Themes")
            }

            Section {
                HStack {
                    Button("Duplicate…", systemImage: "plus.square.on.square") {
                        newThemeName = "My Rafu Theme"
                        isCreating = true
                    }
                    .help("Create an editable copy of the active theme")
                    Button("Import…", systemImage: "square.and.arrow.down") {
                        isImporting = true
                    }
                    .help("Import a theme from a JSON file")
                    Button("Reload Themes", systemImage: "arrow.clockwise") {
                        Task { await reloadThemes() }
                    }
                    .help("Read the theme folder again")
                    Button("Show Theme Folder", systemImage: "folder") {
                        revealThemeFolder()
                    }
                    .help("Show the theme folder in Finder")
                }
                .fixedSize(horizontal: true, vertical: false)
            } header: {
                Text("Manage Themes")
            } footer: {
                Text(
                    "Duplicate a theme to edit Rafu’s JSON color tokens, or import a validated theme. "
                        + "Changes take effect after Reload Themes; restarting is not required."
                )
            }
        }
        .task { await reloadThemes() }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            Task { await importTheme(result) }
        }
        .sheet(isPresented: $isCreating) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Duplicate Theme").font(.headline)
                TextField("Theme name", text: $newThemeName)
                Text("The JSON copy is stored in Rafu’s theme folder and selected immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { isCreating = false }
                    Button("Duplicate") { Task { await createThemeCopy() } }
                        .buttonStyle(RafuProminentButtonStyle())
                        .disabled(
                            newThemeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(20)
            .frame(width: 420)
        }
        .alert("Theme", isPresented: statusBinding) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    // MARK: Selection

    private var systemIsDark: Bool { systemScheme == .dark }

    private var selection: ThemeAppearancePreference.Selection {
        ThemeAppearancePreference.Selection(
            themeChoice: themeChoice, lightIdentifier: lightChoice, darkIdentifier: darkChoice)
    }

    private func apply(_ newSelection: ThemeAppearancePreference.Selection) {
        themeChoice = newSelection.themeChoice
        lightChoice = newSelection.lightIdentifier
        darkChoice = newSelection.darkIdentifier
        themeRevision &+= 1
    }

    private func choose(_ option: ThemeOption) {
        apply(selection.selecting(option.id, isDark: option.isDark))
    }

    private var followsSystemBinding: Binding<Bool> {
        Binding(
            get: { selection.followsSystem },
            set: { apply(selection.settingFollowsSystem($0, systemIsDark: systemIsDark)) }
        )
    }

    private func pairBinding(isDark: Bool) -> Binding<String> {
        Binding(
            get: { isDark ? selection.darkIdentifier : selection.lightIdentifier },
            set: { apply(selection.selecting($0, isDark: isDark)) }
        )
    }

    private var fixedBinding: Binding<String> {
        Binding(
            get: { themeChoice },
            set: { identifier in
                guard let option = options.first(where: { $0.id == identifier }) else { return }
                choose(option)
            }
        )
    }

    private func badge(for option: ThemeOption) -> String? {
        guard selection.followsSystem else { return nil }
        if option.id == selection.lightIdentifier && option.id == selection.darkIdentifier {
            return "Light and Dark"
        }
        if option.id == selection.lightIdentifier { return "Light" }
        if option.id == selection.darkIdentifier { return "Dark" }
        return nil
    }

    private func themePicker(
        _ title: String,
        options: [ThemeOption],
        selection: Binding<String>
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(options) { option in
                Text(option.name).tag(option.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .frame(minWidth: SettingsPresentationLayout.minimumPopupWidth, alignment: .trailing)
    }

    // MARK: Options

    private var options: [ThemeOption] {
        builtInOptions + customOptions
    }

    private var builtInOptions: [ThemeOption] {
        RafuThemeChoice.allCases.filter { $0 != .system }.map { choice in
            let theme = RafuThemeCatalog.resolved(choice: choice, systemScheme: systemScheme)
            return ThemeOption(
                id: choice.rawValue, name: choice.title, isDark: theme.isDark, theme: theme)
        }
    }

    private var selectedThemeURL: URL? {
        let identifier = selection.activeIdentifier(systemIsDark: systemIsDark)
        if let choice = RafuThemeChoice(rawValue: identifier) {
            return RafuThemeCatalog.resourceURL(for: choice)
        }
        return userThemes.first(where: { $0.id == identifier })?.fileURL
    }

    private var statusBinding: Binding<Bool> {
        Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )
    }

    // MARK: Actions

    private func reloadThemes() async {
        do {
            let installed = try await service.installedThemes()
            userThemes = installed
            customOptions = installed.compactMap { descriptor -> ThemeOption? in
                guard let data = try? Data(contentsOf: descriptor.fileURL),
                    let theme = try? JSONDecoder().decode(RafuTheme.self, from: data)
                else { return nil }
                return ThemeOption(
                    id: descriptor.id, name: theme.name, isDark: theme.isDark, theme: theme)
            }
            // A deleted custom theme must not stay selected anywhere.
            let known = Set(installed.map(\.id))
            func isMissing(_ identifier: String) -> Bool {
                identifier.hasPrefix("user:") && !known.contains(identifier)
            }
            if isMissing(themeChoice) { themeChoice = RafuThemeChoice.system.rawValue }
            if isMissing(lightChoice) { lightChoice = ThemeAppearancePreference.defaultLightIdentifier }
            if isMissing(darkChoice) { darkChoice = ThemeAppearancePreference.defaultDarkIdentifier }
            themeRevision &+= 1
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func importTheme(_ result: Result<[URL], any Error>) async {
        do {
            guard let url = try result.get().first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let descriptor = try await service.importTheme(from: url)
            await reloadThemes()
            apply(selection.selecting(descriptor.id, isDark: descriptor.appearance == "dark"))
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func createThemeCopy() async {
        do {
            guard let source = selectedThemeURL ?? RafuThemeCatalog.resourceURL(for: .indigo)
            else { return }
            let descriptor = try await service.createCopy(from: source, named: newThemeName)
            isCreating = false
            await reloadThemes()
            apply(selection.selecting(descriptor.id, isDark: descriptor.appearance == "dark"))
            NSWorkspace.shared.activateFileViewerSelecting([descriptor.fileURL])
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func revealThemeFolder() {
        do {
            try FileManager.default.createDirectory(
                at: ThemeFileService.themesDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(ThemeFileService.themesDirectory)
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}

/// One selectable theme: a built-in or a custom file. `isDark` decides which
/// Follow System slot it can fill.
private struct ThemeOption: Identifiable {
    let id: String
    let name: String
    let isDark: Bool
    let theme: RafuTheme
}

/// A theme card that behaves as a radio button: the active theme has an
/// accent ring and a check mark (never colour alone).
private struct ThemeSettingsCard: View {
    let theme: RafuTheme
    let selected: Bool
    let badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(Color(rafuHex: theme.ui.accent)).frame(width: 10, height: 10)
                Text(theme.name).font(.callout.weight(.medium)).lineLimit(1)
                    .foregroundStyle(Color(rafuHex: theme.ui.textPrimary))
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color(rafuHex: theme.ui.accent))
                        .accessibilityHidden(true)
                }
            }
            HStack(spacing: 4) {
                ForEach(
                    [theme.editor.background, theme.ui.elevatedBackground, theme.ui.accent],
                    id: \.self
                ) { value in
                    RoundedRectangle(cornerRadius: 3).fill(Color(rafuHex: value)).frame(height: 22)
                }
            }
            if let badge {
                Text(badge)
                    .font(.caption2)
                    .foregroundStyle(Color(rafuHex: theme.ui.textSecondary))
            }
        }
        .padding(10)
        .background(Color(rafuHex: theme.ui.appBackground), in: .rect(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9).stroke(
                selected ? Color(rafuHex: theme.ui.accent) : Color(rafuHex: theme.ui.borderSubtle),
                lineWidth: selected ? 2 : 1
            )
        }
    }
}
