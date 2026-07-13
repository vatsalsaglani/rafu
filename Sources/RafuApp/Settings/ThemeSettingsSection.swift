import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ThemeSettingsSection: View {
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @Environment(\.colorScheme) private var systemScheme
    @State private var userThemes: [UserThemeDescriptor] = []
    @State private var isImporting = false
    @State private var isCreating = false
    @State private var newThemeName = "My Rafu Theme"
    @State private var statusMessage: String?

    private let service = ThemeFileService()

    var body: some View {
        Section("Theme") {
            Picker("Active theme", selection: $themeChoice) {
                Section("Built in") {
                    ForEach(RafuThemeChoice.allCases) { choice in
                        Text(choice.title).tag(choice.rawValue)
                    }
                }
                if !userThemes.isEmpty {
                    Section("Custom") {
                        ForEach(userThemes) { theme in
                            Text(theme.name).tag(theme.id)
                        }
                    }
                }
            }

            LazyVGrid(columns: [.init(.adaptive(minimum: 142), spacing: 10)], spacing: 10) {
                ForEach(swatches) { swatch in
                    ThemeSettingsCard(theme: swatch.theme, selected: themeChoice == swatch.id)
                        .contentShape(.rect)
                        .onTapGesture { themeChoice = swatch.id }
                }
            }

            HStack {
                Button("Create Copy…", systemImage: "plus.square.on.square") {
                    newThemeName = "My Rafu Theme"
                    isCreating = true
                }
                Button("Import JSON…", systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                Button("Reload", systemImage: "arrow.clockwise") {
                    Task { await reloadThemes() }
                }
                Spacer()
                Button("Reveal Theme Folder", systemImage: "folder") {
                    revealThemeFolder()
                }
            }
            .labelStyle(.iconOnly)

            Text(
                "Create a copy to edit Rafu’s JSON color tokens, or import a validated theme. "
                    + "Changes take effect after Reload; restarting is not required."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
                Text("Create Theme Copy").font(.headline)
                TextField("Theme name", text: $newThemeName)
                Text("The JSON copy is stored in Rafu’s theme folder and selected immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { isCreating = false }
                    Button("Create") { Task { await createThemeCopy() } }
                        .buttonStyle(.borderedProminent)
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

    private var swatches: [ThemeSwatchItem] {
        let builtIns = RafuThemeChoice.allCases.filter { $0 != .system }.map {
            ThemeSwatchItem(
                id: $0.rawValue,
                theme: RafuThemeCatalog.resolved(choice: $0, systemScheme: systemScheme)
            )
        }
        let custom = userThemes.compactMap { descriptor -> ThemeSwatchItem? in
            guard let data = try? Data(contentsOf: descriptor.fileURL),
                let theme = try? JSONDecoder().decode(RafuTheme.self, from: data)
            else { return nil }
            return ThemeSwatchItem(id: descriptor.id, theme: theme)
        }
        return builtIns + custom
    }

    private var selectedThemeURL: URL? {
        if let choice = RafuThemeChoice(rawValue: themeChoice) {
            return RafuThemeCatalog.resourceURL(for: choice)
        }
        return userThemes.first(where: { $0.id == themeChoice })?.fileURL
    }

    private var statusBinding: Binding<Bool> {
        Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )
    }

    private func reloadThemes() async {
        do {
            userThemes = try await service.installedThemes()
            if themeChoice.hasPrefix("user:"),
                !userThemes.contains(where: { $0.id == themeChoice })
            {
                themeChoice = RafuThemeChoice.system.rawValue
            }
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
            themeChoice = descriptor.id
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
            themeChoice = descriptor.id
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

private struct ThemeSwatchItem: Identifiable {
    let id: String
    let theme: RafuTheme
}

private struct ThemeSettingsCard: View {
    let theme: RafuTheme
    let selected: Bool

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
