import CoreGraphics

/// Everything the HUD layout needs from a screen, captured as plain values
/// so the math is testable without `NSScreen` (terminal-notch-hud.md N-1).
/// The ONLY place these are built from a real screen is the small
/// `@MainActor` adapter in `NotchHUDWindow.swift`; everything downstream of
/// this struct is pure.
nonisolated struct NotchScreenMetrics: Equatable, Sendable {
    /// Screen frame in global coordinates (bottom-left origin).
    let frame: CGRect
    /// `NSScreen.visibleFrame` — the frame minus the menu bar and Dock.
    /// Carried separately from `frame` because the NON-notch fallback must
    /// anchor "just below the menu bar", and the menu bar's bottom edge is
    /// only knowable as `visibleFrame.maxY` (a non-notch screen reports a
    /// zero safe-area inset, so the inset cannot stand in for it).
    let visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top` — 0 on non-notch displays.
    let safeAreaTopInset: CGFloat
    /// `NSScreen.auxiliaryTopLeftArea` — nil on non-notch displays.
    let auxiliaryTopLeft: CGRect?
    /// `NSScreen.auxiliaryTopRightArea` — nil on non-notch displays.
    let auxiliaryTopRight: CGRect?
    /// Whether this is the Mac's built-in display (`CGDisplayIsBuiltin`).
    /// `var` with a default so the memberwise initializer keeps it optional:
    /// every existing call site that builds metrics without it stays valid.
    var isBuiltin: Bool = false
    /// `NSScreen.backingScaleFactor` — device pixels per point. Used only to
    /// snap the Dynamic Island capsule's fractional edges to whole pixels
    /// (`NotchHUDGeometry.pixelAligned(_:scale:)`). `var` with a default for
    /// the same reason as `isBuiltin`.
    var backingScaleFactor: CGFloat = 2
}

/// What sits at the top centre of a screen, derived from geometry only
/// (`NotchHUDGeometry.cutout(for:)`):
///
/// - `.none`: no top safe-area inset, or the auxiliary areas cannot bound a
///   housing. The menu bar runs edge to edge.
/// - `.notch`: a wide camera housing that the menu bar flows around
///   (185 x 33 pt on a 14-inch MacBook Pro).
/// - `.islandCamera`: a small hole-punch camera with a system Dynamic Island
///   drawn around it (59 x 40 pt on Mac17,13). macOS draws its own black
///   capsule there, so Rafu must not paint a band from the screen top.
nonisolated enum NotchCutout: Equatable, Sendable {
    case none
    case notch
    case islandCamera
}

/// The HUD's two presentations (terminal-notch-hud.md N-4): a compact pill
/// and an expanded card with the full bounded snippet and the reply field.
nonisolated enum NotchHUDState: Equatable, Sendable {
    case compact
    case expanded
}

/// Pure notch/HUD geometry. The platform exposes NO notch API — only
/// geometry: the camera housing rect is DERIVED from the two auxiliary top
/// areas and the top safe-area inset (verified on a 14-inch MacBook Pro:
/// 1710×1107 screen, inset 33, aux areas (0,1074,763,33) and
/// (948,1074,762,33) → notch (763,1074,185,33); verified on Mac17,13 with a
/// Dynamic Island: 1512×993 screen, inset 40, aux areas (0,953,726.5,40) and
/// (785.5,953,726.5,40) → island camera (726.5,953,59,40)).
nonisolated enum NotchHUDGeometry {
    /// A housing narrower than this many top insets is a hole-punch camera
    /// with a system Dynamic Island, not a notch: the island camera is
    /// 59 pt wide beside a 40 pt inset (ratio 1.5), a notch is 185 pt wide
    /// beside a 33 pt inset (ratio 5.6). 3 sits well clear of both.
    static let islandWidthToInsetRatio: CGFloat = 3

    /// The camera housing rect in screen coordinates, whatever its kind, or
    /// `nil` when the screen has none (inset is 0, either auxiliary area is
    /// missing, or the derived width is non-positive).
    static func housingRect(for metrics: NotchScreenMetrics) -> CGRect? {
        guard metrics.safeAreaTopInset > 0,
            let left = metrics.auxiliaryTopLeft,
            let right = metrics.auxiliaryTopRight
        else { return nil }
        let width = right.minX - left.maxX
        guard width > 0 else { return nil }
        return CGRect(
            x: left.maxX,
            y: metrics.frame.maxY - metrics.safeAreaTopInset,
            width: width,
            height: metrics.safeAreaTopInset
        )
    }

    /// Classifies the top of the screen. See `NotchCutout`.
    static func cutout(for metrics: NotchScreenMetrics) -> NotchCutout {
        guard let housing = housingRect(for: metrics) else { return .none }
        return housing.width < islandWidthToInsetRatio * metrics.safeAreaTopInset
            ? .islandCamera : .notch
    }

    /// The notch rect in screen coordinates, or `nil` when the screen has
    /// no NOTCH — including a screen with an island camera. Every consumer
    /// of this rect paints a black band from the screen top to merge with
    /// the housing; beside a Dynamic Island that band would collide with
    /// the system capsule, so an island screen takes the no-notch layout
    /// here and its own geometry in `NotchIslandGeometry`.
    static func notchRect(for metrics: NotchScreenMetrics) -> CGRect? {
        cutout(for: metrics) == .notch ? housingRect(for: metrics) : nil
    }

    /// `value` rounded to the nearest device pixel. `scale` below 1 counts
    /// as 1, so a bad scale factor can never divide by zero.
    static func pixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        let scale = max(scale, 1)
        return (value * scale).rounded() / scale
    }

    /// Where the HUD window goes. With a notch: hanging just below it
    /// (top edge flush with the notch's bottom), horizontally centered on
    /// it, at least as wide as the notch. Without one: top-center just
    /// below the menu bar (top edge at `visibleFrame.maxY`). The result is
    /// always fully within `frame` — clamped on every edge.
    ///
    /// Both states pin the same top edge and width, so an `.expanded`
    /// `contentSize` (taller, same width) grows the HUD DOWNWARD only, as
    /// the phase brief locks. `state` travels with the size so the call
    /// site states which presentation the size belongs to and per-state
    /// rules can be added without a signature change.
    static func hudFrame(
        for metrics: NotchScreenMetrics,
        contentSize: CGSize,
        state: NotchHUDState
    ) -> CGRect {
        _ = state
        let requestedWidth: CGFloat
        let centerX: CGFloat
        let topY: CGFloat
        if let notch = notchRect(for: metrics) {
            // SEAMLESS: the window's top edge sits at the SCREEN top (not
            // below the menu-bar band) so its black band region merges with
            // the physical notch housing — the whole reason this HUD exists
            // visually. The band height is added to the content height; the
            // view pads its content down by `bandInset(for:)` so nothing is
            // laid out beside the housing. (`.statusBar` window level is 25,
            // the menu bar is 24, so the band region genuinely covers it.)
            requestedWidth = max(contentSize.width, notch.width)
            centerX = notch.midX
            topY = notch.maxY
        } else {
            requestedWidth = contentSize.width
            centerX = metrics.frame.midX
            topY = metrics.visibleFrame.maxY
        }
        // "Always fully within frame" also covers degenerate oversized
        // content: clamp the size to the frame first, then the origin.
        let width = min(requestedWidth, metrics.frame.width)
        let bandHeight = notchRect(for: metrics) != nil ? metrics.safeAreaTopInset : 0
        let height = min(contentSize.height + bandHeight, metrics.frame.height)
        let x = min(max(centerX - width / 2, metrics.frame.minX), metrics.frame.maxX - width)
        let y = min(max(topY - height, metrics.frame.minY), metrics.frame.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Which display the notch surfaces belong on when more than one is
/// attached. Pure so the rule is testable without `NSScreen` (the adapter
/// in `NotchHUDWindow.swift` supplies the candidates).
nonisolated enum NotchScreenSelection {
    /// Picks the screen the HUD and companion strip should occupy, given
    /// `candidates` in the caller's preference order (the screen the user
    /// is working on first, then every attached screen).
    ///
    /// A screen with a REAL notch ALWAYS wins, even when it is not the one
    /// the key window sits on. These surfaces exist to fill the physical
    /// housing; following the active window onto an external display moved
    /// them to that display's non-notch fallback position — and for the
    /// companion strip, whose geometry returns `nil` without a notch,
    /// removed them entirely. Working in a Rafu window on an external
    /// monitor therefore made the laptop's notch go blank until the window
    /// was dragged back, which is the opposite of an "always-on companion".
    ///
    /// With no notched screen attached (clamshell, desktop Mac, external
    /// only) the first candidate wins, preserving the original
    /// follow-the-key-window behavior for the non-notch fallback layout.
    static func preferred(from candidates: [NotchScreenMetrics]) -> NotchScreenMetrics? {
        candidates.first { NotchHUDGeometry.notchRect(for: $0) != nil } ?? candidates.first
    }

    /// The companion's screen. Like `preferred(from:)`, except that a screen
    /// with ANY camera cutout (a notch or an island camera) wins first, and
    /// with none attached the built-in display wins before the active
    /// window's screen (Cider's `BuiltinDisplay` rule): a floating pill on a
    /// Mac without a notch belongs on the laptop's own screen, not on
    /// whichever external monitor currently holds the key window. The
    /// attention drop-down keeps following the key window; only the
    /// always-on companion is anchored to the cutout or built-in display.
    static func preferredForCompanion(from candidates: [NotchScreenMetrics])
        -> NotchScreenMetrics?
    {
        candidates.first { NotchHUDGeometry.cutout(for: $0) != .none }
            ?? candidates.first { $0.isBuiltin }
            ?? candidates.first
    }
}

extension NotchHUDGeometry {
    /// Top padding the HUD content needs so it lays out BELOW the physical
    /// notch housing: the safe-area band height on a notched screen, 0 on
    /// the non-notch fallback (where the window already sits below the
    /// menu bar).
    nonisolated static func bandInset(for metrics: NotchScreenMetrics) -> CGFloat {
        notchRect(for: metrics) != nil ? metrics.safeAreaTopInset : 0
    }
}
