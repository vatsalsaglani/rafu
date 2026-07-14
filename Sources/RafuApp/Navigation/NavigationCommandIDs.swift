import Foundation

/// Reserved identifiers for navigation-related menu commands and
/// command-palette entries. A namespace of constants only — increment 0
/// reserves the names both lanes agree on; wiring them into menus, the
/// command palette, and the status item lands starting with increment 1
/// (`showResources`) and increment 10 (the rest).
enum NavigationCommandID {
    static let goToDefinition = "navigation.goToDefinition"
    static let goToDeclaration = "navigation.goToDeclaration"
    static let findReferences = "navigation.findReferences"
    static let workspaceSymbolSearch = "navigation.workspaceSymbolSearch"
    static let openLanguageServersSettings = "navigation.openLanguageServersSettings"
    static let showResources = "navigation.showResources"
}
