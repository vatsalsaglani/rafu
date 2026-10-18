import AppKit

/// Optional, nonessential haptic feedback for direct manipulation on the
/// Canvas. Only Force Touch trackpads play it; the system default performer
/// already honours the input device, accessibility settings and user
/// preferences. Apple's guidance: respond only to user-initiated actions, so
/// never call this for incoming messages, link state changes or results.
/// Every call site must also show visual feedback (a guide, a port, a stop).
enum RafuHaptics {
    /// Settings ▸ General ▸ "Haptic feedback on the Canvas". Default: on.
    static let canvasHapticsDefaultsKey = "canvasHapticsEnabled"
    static let minimumInterval: Duration = .milliseconds(100)

    private static var lastPerformed: [String: ContinuousClock.Instant] = [:]

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: canvasHapticsDefaultsKey) as? Bool ?? true
    }

    /// Alignment feedback: a snap to a guide, a port, a minimum size, or the
    /// 100% zoom detent. Throttled to one per `minimumInterval` per channel.
    static func alignment(channel: String = "canvas") {
        guard isEnabled else { return }
        let now = ContinuousClock.now
        if let last = lastPerformed[channel], last.duration(to: now) < minimumInterval {
            return
        }
        lastPerformed[channel] = now
        NSHapticFeedbackManager.defaultPerformer.perform(
            .alignment, performanceTime: .drawCompleted)
    }
}
