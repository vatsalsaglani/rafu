import Foundation

/// The one URL a Rafu widget opens: `rafu://usage` for Rafu, and
/// `rafu-lightning://usage` for Rafu Lightning, so a tap on a Lightning
/// widget never opens the release app. `script/build_and_run.sh` registers
/// the scheme in each variant's Info.plist.
///
/// Security: a URL scheme is an entry point any app or web page can call.
/// The app accepts exactly `<scheme>://usage` — no path, query, fragment,
/// user, password, or port — and ignores everything else. The link carries
/// no data, opens no file, and starts no process: it only shows the usage
/// surface.
public enum RafuDeepLink {
    public static let releaseScheme = "rafu"
    public static let lightningScheme = "rafu-lightning"
    public static let usageHost = "usage"

    private static let lightningBundleIdentifier = "dev.vatsalsaglani.rafu.lightning"

    /// The scheme of the variant that owns `bundleIdentifier` (the app's or
    /// its widget extension's, `….lightning.widgets`). An unknown or `nil`
    /// identifier (tests, `swift run`) uses the release scheme.
    public static func scheme(forBundleIdentifier bundleIdentifier: String?) -> String {
        guard let bundleIdentifier else { return releaseScheme }
        return bundleIdentifier == lightningBundleIdentifier
            || bundleIdentifier.hasPrefix(lightningBundleIdentifier + ".")
            ? lightningScheme : releaseScheme
    }

    /// `rafu://usage` or `rafu-lightning://usage`.
    public static func usageURL(scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = usageHost
        // Both scheme constants are valid URL schemes, so this cannot fail.
        return components.url ?? URL(filePath: "/")
    }

    /// `true` only for a URL whose scheme is `scheme` (any case, as URL
    /// schemes are case-insensitive) and whose remaining parts are exactly
    /// host `usage` with an empty path. Everything else is `false`.
    public static func isUsageLink(_ url: URL, scheme: String) -> Bool {
        guard url.absoluteString.utf8.count <= 64,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme.lowercased(),
            components.percentEncodedHost == usageHost,
            components.percentEncodedUser == nil,
            components.percentEncodedPassword == nil,
            components.port == nil,
            components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
            components.percentEncodedQuery == nil,
            components.percentEncodedFragment == nil
        else { return false }
        return true
    }

    /// `true` when `url` uses `scheme` at all, so the app can take it out of
    /// the folder-open path and then ignore it unless `isUsageLink`.
    public static func usesScheme(_ url: URL, scheme: String) -> Bool {
        url.scheme?.lowercased() == scheme.lowercased()
    }
}

/// A theme hex colour as sRGB components, `0...1`. The widget builds its
/// `Color` from this, so the extension never parses theme JSON.
public struct WidgetRGBA: Equatable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    /// `#RRGGBB` or `#RRGGBBAA` (the `#` is optional), as in a Rafu theme
    /// file. `nil` for anything else, so a bad value falls back to a system
    /// colour instead of black.
    public init?(hex: String) {
        let digits = hex.hasPrefix("#") ? hex.dropFirst() : Substring(hex)
        guard digits.count == 6 || digits.count == 8,
            digits.allSatisfy(\.isHexDigit),
            let value = UInt64(digits, radix: 16)
        else { return nil }
        if digits.count == 8 {
            red = Double((value >> 24) & 0xff) / 255
            green = Double((value >> 16) & 0xff) / 255
            blue = Double((value >> 8) & 0xff) / 255
            alpha = Double(value & 0xff) / 255
        } else {
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
            alpha = 1
        }
    }
}
