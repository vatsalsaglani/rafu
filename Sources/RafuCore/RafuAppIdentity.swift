import Foundation

/// The identity of the app bundle that owns the current process.
///
/// The GUI resolves from `Bundle.main`. The bundled CLI first checks its
/// process bundle, then follows its installed symlink back to the enclosing
/// app with `LauncherAppLocator`. A process with no recognized app bundle
/// always falls back to the release identity.
public struct RafuAppIdentity: Hashable, Sendable {
    public let displayName: String
    public let bundleIdentifier: String
    public let applicationSupportDirectory: String
    public let isLightning: Bool

    public static let release = RafuAppIdentity(
        displayName: "Rafu",
        bundleIdentifier: "dev.vatsalsaglani.rafu",
        applicationSupportDirectory: "Rafu",
        isLightning: false
    )

    public static let lightning = RafuAppIdentity(
        displayName: "Rafu Lightning",
        bundleIdentifier: "dev.vatsalsaglani.rafu.lightning",
        applicationSupportDirectory: "Rafu Lightning",
        isLightning: true
    )

    public static var current: RafuAppIdentity {
        if let identity = recognizedIdentity(in: Bundle.main) {
            return identity
        }
        if let bundleURL = LauncherAppLocator.enclosingAppBundle(),
            let bundle = Bundle(url: bundleURL),
            let identity = recognizedIdentity(in: bundle)
        {
            return identity
        }
        return .release
    }

    /// Resolves a supplied bundle for tests and explicit callers. `nil` and
    /// unrecognized bundle identifiers deliberately return release.
    public static func resolve(bundle: Bundle?) -> RafuAppIdentity {
        recognizedIdentity(in: bundle) ?? .release
    }

    public static var defaultApplicationSupportBaseDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public var executableName: String {
        isLightning ? "RafuLightning" : "Rafu"
    }

    public var cliName: String {
        isLightning ? "rafu-lightning" : "rafu"
    }

    public var keychainService: String {
        "\(bundleIdentifier).ai-provider-key"
    }

    /// The cross-surface seam token used by the app icon and notch HUD.
    public var seamColorHex: String {
        isLightning ? "#C0C6CE" : "#E3A857"
    }

    /// The sole constructor for Rafu-owned state below Application Support.
    public func applicationSupportRoot(
        baseDirectory: URL = RafuAppIdentity.defaultApplicationSupportBaseDirectory
    ) -> URL {
        baseDirectory.appending(
            path: applicationSupportDirectory,
            directoryHint: .isDirectory
        )
    }

    private static func recognizedIdentity(in bundle: Bundle?) -> RafuAppIdentity? {
        switch bundle?.bundleIdentifier {
        case RafuAppIdentity.release.bundleIdentifier:
            .release
        case RafuAppIdentity.lightning.bundleIdentifier:
            .lightning
        default:
            nil
        }
    }
}
