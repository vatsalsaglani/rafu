import Foundation

/// A terminal session's color TAG (terminal-manager.md T-D).
///
/// Presets are THEME palette tokens, so switching themes restyles every
/// preset-tagged session automatically. `.custom` carries a literal sRGB hex
/// chosen from the system color picker: it is exactly what the user picked
/// and therefore does NOT follow the theme — the deliberate trade for
/// letting people pick any color rather than only the six presets.
///
/// Deliberately no SwiftUI import: resolving a case to an actual `Color` is
/// a view-layer concern (`RafuThemePalette.color(for:)`), keeping this
/// headless-testable and usable from the model layer. Never meaning by
/// color alone (AGENTS) — always shown paired with the session's name and
/// status text. Not persisted: terminal sessions never restore across
/// relaunch (ADR 0004), so neither does their color.
nonisolated enum TerminalSessionColor: Equatable, Hashable, Sendable, Codable {
    case accent
    case info
    case success
    case warning
    case error
    case muted
    /// `#RRGGBB`, normalized uppercase by `custom(hex:)`.
    case custom(hex: String)

    /// The theme-following presets, in swatch order. Not `CaseIterable`:
    /// `.custom` has an associated value, so an exhaustive case list would
    /// be infinite.
    static let presets: [TerminalSessionColor] = [
        .accent, .info, .success, .warning, .error, .muted,
    ]

    /// Normalizes any `#RGB`/`#RRGGBB`/`RRGGBB` spelling to `#RRGGBB`, or
    /// returns nil when the string is not a hex color. Use this rather than
    /// the raw case so two spellings of one color compare equal.
    static func custom(fromHex raw: String) -> TerminalSessionColor? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if value.hasPrefix("#") { value.removeFirst() }
        if value.count == 3 {
            value = value.map { "\($0)\($0)" }.joined()
        }
        guard value.count == 6, value.allSatisfy({ $0.isHexDigit }) else { return nil }
        return .custom(hex: "#\(value)")
    }

    var displayName: String {
        switch self {
        case .accent: "Accent"
        case .info: "Blue"
        case .success: "Green"
        case .warning: "Amber"
        case .error: "Red"
        case .muted: "Gray"
        case .custom(let hex): hex
        }
    }

    /// Stable string form. Presets encode as their name so a preset stays a
    /// preset (and keeps following the theme); customs encode as their hex.
    var storageValue: String {
        switch self {
        case .accent: "accent"
        case .info: "info"
        case .success: "success"
        case .warning: "warning"
        case .error: "error"
        case .muted: "muted"
        case .custom(let hex): hex
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "accent": self = .accent
        case "info": self = .info
        case "success": self = .success
        case "warning": self = .warning
        case "error": self = .error
        case "muted": self = .muted
        default:
            guard let custom = TerminalSessionColor.custom(fromHex: storageValue) else {
                return nil
            }
            self = custom
        }
    }

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let value = TerminalSessionColor(storageValue: raw) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unknown color \(raw)")
            )
        }
        self = value
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(storageValue)
    }
}
