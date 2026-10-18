import SwiftUI

/// Motion values for the macOS redesign (`docs/plans/phases/macos-redesign.md`,
/// section 08 of the review). Pointer-driven changes (drag, resize, pinch,
/// scroll) and keyboard-driven changes (typing, caret, focus rings, tab and
/// list navigation) never animate; these values cover discrete changes only.
enum RafuMotion {
    // Hover, press, selection.
    static let hoverIn: Animation = .easeOut(duration: 0.10)
    static let hoverOut: Animation = .easeOut(duration: 0.16)
    static let pressRelease: Animation = .easeOut(duration: 0.12)
    static let selection: Animation = .easeOut(duration: 0.08)
    /// Delay before contextual hover controls hide, so they do not flicker.
    static let contextualHideDelay: TimeInterval = 0.30

    // Canvas nodes.
    static let nodeCreate: Animation = .spring(response: 0.28, dampingFraction: 0.9)
    static let nodeRemove: Animation = .easeIn(duration: 0.14)
    static let lift: Animation = .easeOut(duration: 0.12)
    static let setDown: Animation = .easeOut(duration: 0.16)
    static let resizeReturn: Animation = .spring(response: 0.25, dampingFraction: 0.85)

    // Connections and edges.
    static let targetHighlight: Animation = .easeOut(duration: 0.10)
    static let connectionCancel: Animation = .easeIn(duration: 0.16)
    static let edgeDrawIn: Animation = .easeOut(duration: 0.24)
    static let stateCrossFade: Animation = .easeInOut(duration: 0.16)
    /// One travelling dot per accepted session message.
    static let messageTravel: TimeInterval = 0.5
    /// More than this many messages inside `messageBurstWindow` show only a count.
    static let messageBurstLimit = 3
    static let messageBurstWindow: TimeInterval = 2

    // Notes, zoom, panels, confirmations.
    static let noteModeSwap: Animation = .easeInOut(duration: 0.12)
    static let zoomStep: Animation = .easeInOut(duration: 0.18)
    static let zoomToFit: Animation = .easeInOut(duration: 0.26)
    static let panelToggle: Animation = .easeInOut(duration: 0.20)
    static let successHold: TimeInterval = 1.2
    static let guideFadeOut: Animation = .easeOut(duration: 0.15)

    /// The Reduce Motion replacement for travel, scale and spring motion.
    static let reducedFade: Animation = .easeOut(duration: 0.12)

    /// Returns `animation`, or `reduced` (default: no animation) when Reduce
    /// Motion is on.
    static func resolve(
        _ animation: Animation, reduceMotion: Bool, reduced: Animation? = nil
    ) -> Animation? {
        reduceMotion ? reduced : animation
    }
}
