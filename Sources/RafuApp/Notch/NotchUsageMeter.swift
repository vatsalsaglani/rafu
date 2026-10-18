import Foundation

/// How a usage window renders as a meter. Pure, so the clamping and the
/// thresholds are testable without a view. Thresholds are
/// `UsageDisplayPolicy`'s, so the meter, the text, and the emphasis agree.
nonisolated enum NotchUsageMeter {
    nonisolated enum Level: Equatable, Sendable {
        case normal
        case high
        case critical
    }

    /// The filled fraction, 0...1. `nil` when the window has no percentage
    /// (token totals, cost lines) or the value is not a finite number.
    static func fraction(percent: Double?) -> Double? {
        guard let percent, percent.isFinite else { return nil }
        return min(max(percent / 100, 0), 1)
    }

    static func level(percent: Double?) -> Level {
        guard let percent, percent.isFinite else { return .normal }
        if percent >= UsageDisplayPolicy.criticalUsageThreshold { return .critical }
        if percent >= UsageDisplayPolicy.highUsageThreshold { return .high }
        return .normal
    }

    /// The text beside a meter: the rounded percentage (with a warning glyph
    /// at the critical level, so the signal does not depend on colour), the
    /// compact token total, or `nil`.
    static func valueText(for window: UsageWindow) -> String? {
        if let percent = window.percent, percent.isFinite {
            let text = "\(Int(percent.rounded()))%"
            return level(percent: percent) == .critical ? text + " ⚠" : text
        }
        if let tokens = window.tokens {
            return UsageFormat.compactTokenCount(tokens) + " tok"
        }
        return nil
    }
}
