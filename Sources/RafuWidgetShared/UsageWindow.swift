import Foundation

/// One rate-limit window inside a `UsageSnapshot` — a real percentage OR a
/// token total, never both fabricated to fill the missing field (mirrors
/// the shipped `AgentUsageWindow`'s discipline).
///
/// Shared by the app and the WidgetKit extension; the app re-exports this
/// module, so every `UsageWindow(label:percent:tokens:resetsAt:)` call site
/// in `RafuApp` compiles unchanged.
public nonisolated struct UsageWindow: Equatable, Sendable {
    /// "5h" / "7d" / "monthly" — a human label, not a raw window size.
    public let label: String
    public let percent: Double?
    public let tokens: Int?
    public let resetsAt: Date?
    /// The window's length in minutes (300 for a 5-hour session, 10_080 for
    /// a weekly limit) when the provider reports or documents it. Additive:
    /// it defaults to `nil`, so every existing
    /// `UsageWindow(label:percent:tokens:resetsAt:)` call keeps compiling.
    /// `UsagePace` needs it, with `resetsAt`, to find the window's start.
    public var windowMinutes: Int? = nil

    public init(
        label: String, percent: Double?, tokens: Int?, resetsAt: Date?, windowMinutes: Int? = nil
    ) {
        self.label = label
        self.percent = percent
        self.tokens = tokens
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}
