import AppKit
import SwiftUI

/// The ONLY place `NSScreen` is read for HUD geometry (terminal-notch-hud.md
/// N-1): builds the pure `NotchScreenMetrics` value that every downstream
/// rule consumes, keeping `NotchHUDGeometry` headless-testable.
@MainActor
enum NotchScreenAdapter {
    static func metrics(for screen: NSScreen) -> NotchScreenMetrics {
        NotchScreenMetrics(
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTopInset: screen.safeAreaInsets.top,
            auxiliaryTopLeft: screen.auxiliaryTopLeftArea,
            auxiliaryTopRight: screen.auxiliaryTopRightArea
        )
    }

    /// Screen choice (N-1): the screen containing the key window, else
    /// `NSScreen.main`, else the first screen. Recomputed by the controller
    /// on every show and on `NSApplication.didChangeScreenParametersNotification`
    /// (dock/undock, resolution change).
    static func currentMetrics() -> NotchScreenMetrics? {
        let screen = NSApp.keyWindow?.screen ?? NSScreen.main ?? NSScreen.screens.first
        return screen.map(metrics(for:))
    }
}

/// The HUD's window (terminal-notch-hud.md N-2): a borderless, always-on-top,
/// NON-activating panel faking the notch shape — the same technique every
/// notch utility uses, since the platform has no notch API.
///
/// Focus recipe (the part everything else depends on): the panel appears via
/// `orderFrontRegardless()` and can become key ONLY while the reply field is
/// engaged — `allowsKeyStatus` is flipped by `NotchHUDController` exactly
/// when the user clicks the reply field, and flipped back on send/Escape or
/// when the panel resigns key. Until then it cannot take a keystroke from
/// whatever the user is typing in, and because the app is never activated,
/// disengaging hands key status straight back — nothing is re-activated.
final class NotchHUDPanel: NSPanel {
    /// The single input to `canBecomeKey` — see the type doc above.
    var allowsKeyStatus = false

    /// Escape forwards here from AppKit's `cancelOperation` while the panel
    /// is key; wired to the controller's dismiss.
    var onCancel: (() -> Void)?

    /// SCREEN-coordinate regions that must stay click-through
    /// (terminal-notch-hud.md NC-B) — see `NotchHUDPassthroughHostingView`,
    /// the ONE place this actually takes effect (AppKit hit-testing is
    /// view-level, not window-level). Empty for the v1 attention drop-down
    /// (the whole panel stays interactive, unchanged from N-2); the
    /// companion resting strip sets this to
    /// `NotchCompanionGeometry.clickThroughRegions(for:)` — the physical
    /// notch — and clears it back to empty while peeking/pinned, when the
    /// whole expanded panel is interactive.
    var clickThroughRegions: [CGRect] = [] {
        didSet {
            (contentView as? any NotchHUDPassthroughHosting)?.clickThroughRegions =
                clickThroughRegions
        }
    }

    override var canBecomeKey: Bool { allowsKeyStatus }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Floats over normal windows, below the screensaver.
        level = .statusBar
        // `.fullScreenAuxiliary` is REQUIRED: without it the HUD vanishes
        // exactly when an agent-watching user has a window full-screened —
        // the scenario this feature exists for.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Type-erased seam onto `NotchHUDPassthroughHostingView<Content>`'s
/// `clickThroughRegions` — `NotchHUDPanel.clickThroughRegions`'s `didSet`
/// needs to reach into `contentView` without knowing which SwiftUI root the
/// panel is currently hosting.
protocol NotchHUDPassthroughHosting: AnyObject {
    var clickThroughRegions: [CGRect] { get set }
}

/// The hit-transparent content view (terminal-notch-hud.md NC-B, "Resting":
/// "click-through everywhere except the wings"). AppKit's mouse routing is
/// entirely view-level — there is no window-level "click-through this
/// rect" API — so this is the ONE place `NotchHUDPanel.clickThroughRegions`
/// takes effect: `hitTest(_:)` returning `nil` for a point tells AppKit no
/// view in this window claims it, which is exactly the mechanism the
/// notch-utility prior art (agent-notch's technique notes,
/// terminal-notch-hud.md's "Prior art" section) uses to let an unclaimed
/// click fall through to whatever is behind the window — the real menu bar
/// content flanking the notch, in this case.
///
/// Generic over the SwiftUI root so both the v1 attention drop-down
/// (`NotchHUDView`, `clickThroughRegions` always empty — see
/// `NotchHUDController.presentPanel()`) and the companion resting strip
/// (`NotchCompanionView`, notch-only regions) share one implementation
/// instead of duplicating the hit-test override per root type.
final class NotchHUDPassthroughHostingView<Content: View>: NSHostingView<Content>,
    NotchHUDPassthroughHosting
{
    var clickThroughRegions: [CGRect] = []

    /// This view is always installed as `NSWindow.contentView` — the root
    /// of the hierarchy, no superview — so AppKit hands `hitTest(_:)` a
    /// point already in the WINDOW's own coordinate system (the documented
    /// "superview's coordinate system" contract degenerates to the window
    /// itself for a view with no superview). `window.convertPoint(toScreen:)`
    /// is therefore the correct, direct conversion to the SCREEN coordinates
    /// `clickThroughRegions` is expressed in (matching
    /// `NotchCompanionGeometry`'s own coordinate space).
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, !clickThroughRegions.isEmpty else { return super.hitTest(point) }
        let screenPoint = window.convertPoint(toScreen: point)
        if clickThroughRegions.contains(where: { $0.contains(screenPoint) }) {
            return nil
        }
        return super.hitTest(point)
    }
}
