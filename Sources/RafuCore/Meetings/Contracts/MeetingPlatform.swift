import Foundation

/// Whether this Mac can use Meetings. Meetings needs macOS 26; the package
/// minimum stays macOS 15, so on macOS 15 each entry point shows and is not
/// active.
public enum MeetingsAvailability: Hashable, Sendable {
    case available
    case needsMacOS26

    /// Computed one time per process.
    public static let current: MeetingsAvailability = {
        if #available(macOS 26, *) { return .available }
        return .needsMacOS26
    }()

    public var isAvailable: Bool { self == .available }

    /// The user-facing reason when Meetings is not available, else nil.
    public var unavailableReason: String? {
        switch self {
        case .available: nil
        case .needsMacOS26: "Meetings needs macOS 26"
        }
    }
}
