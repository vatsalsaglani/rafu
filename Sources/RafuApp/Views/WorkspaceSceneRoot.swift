import SwiftUI

struct WorkspaceSceneRoot: View {
    @State private var session = WorkspaceSession()
    @AppStorage("themeChoice") private var themeChoice = RafuThemeChoice.system.rawValue
    @AppStorage("themeRevision") private var themeRevision = 0
    @Environment(\.colorScheme) private var systemScheme

    var body: some View {
        WorkspaceWindowView(session: session)
            .environment(\.rafuTheme, theme)
            .preferredColorScheme(preferredColorScheme)
            .task { await session.restoreLastWorkspaceIfAvailable() }
    }

    private var choice: RafuThemeChoice? { RafuThemeChoice(rawValue: themeChoice) }
    private var theme: RafuTheme {
        _ = themeRevision
        return RafuThemeCatalog.resolved(identifier: themeChoice, systemScheme: systemScheme)
    }
    private var preferredColorScheme: ColorScheme? {
        choice == .system ? nil : theme.colorScheme
    }
}
