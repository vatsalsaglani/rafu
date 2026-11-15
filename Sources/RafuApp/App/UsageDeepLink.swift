import AppKit
import OSLog

/// Which surface a `rafu://usage` widget link shows. Pure, so each rule has
/// a test.
nonisolated enum UsageDeepLinkTarget: Equatable, Sendable {
    /// The usage glance is a menu bar status item: open its card.
    case menuBarCard
    /// The notch or island panel exists and offers Usage: pin it open on
    /// that section.
    case companionPanel
    /// No companion surface (turned off, or a plain display without the
    /// pill): Settings ▸ Usage.
    case settings

    static func resolve(hasMenuBarItem: Bool, hasPanel: Bool, panelOffersUsage: Bool)
        -> UsageDeepLinkTarget
    {
        if hasMenuBarItem { return .menuBarCard }
        if hasPanel, panelOffersUsage { return .companionPanel }
        return .settings
    }
}

/// Receives the widget's URL (`RafuDeepLink`). Accepts exactly
/// `<scheme>://usage` for this variant's scheme and ignores every other
/// URL: no parameters, no paths, no files, no processes. A link that
/// arrives while the app is still launching waits until launch finishes,
/// so the companion's surfaces exist when it is shown.
///
/// Two delivery paths, both ending in `handle(_:)`: an
/// `NSAppleEventManager` `kAEGetURL` handler (installed by the app
/// delegate), and `application(_:open:)`, which AppKit uses when no such
/// handler is installed.
@MainActor
enum UsageDeepLink {
    private static let log = Logger(subsystem: "dev.vatsalsaglani.rafu", category: "deep-link")
    private static var launchFinished = false
    private static var pendingReveal = false

    /// This variant's scheme: `rafu` or `rafu-lightning`.
    static var scheme: String {
        RafuDeepLink.scheme(forBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    /// `true` when `url` uses this app's scheme, so the caller takes it out
    /// of the folder-open path whether or not it is accepted.
    static func owns(_ url: URL) -> Bool {
        RafuDeepLink.usesScheme(url, scheme: scheme)
    }

    /// Shows the usage surface for an exact usage link; ignores anything
    /// else. Never logs the URL, which a caller controls.
    static func handle(_ url: URL) {
        guard RafuDeepLink.isUsageLink(url, scheme: scheme) else {
            log.notice("Ignored a link that is not the usage link")
            return
        }
        guard launchFinished else {
            pendingReveal = true
            return
        }
        reveal()
    }

    /// Call once from `applicationDidFinishLaunching`, after the companion
    /// activates. Shows a usage link that arrived during launch.
    static func launchDidFinish() {
        launchFinished = true
        guard pendingReveal else { return }
        pendingReveal = false
        // The next main-actor turn: the status item and panel are created
        // in the same launch pass.
        Task { @MainActor in reveal() }
    }

    private static func reveal() {
        NSApp.activate()
        NotchCompanionModel.shared.revealUsage(openSettings: openUsageSettings)
    }

    /// Settings ▸ Usage. SwiftUI's `openSettings` action exists only in a
    /// view, so this performs the app menu's "Settings…" item, which calls
    /// it (`RafuAppCommands`).
    private static func openUsageSettings() {
        SettingsPaneRouter.shared.request(.usage)
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
            let index = appMenu.items.firstIndex(where: {
                $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
            })
        else { return }
        appMenu.performActionForItem(at: index)
    }
}
