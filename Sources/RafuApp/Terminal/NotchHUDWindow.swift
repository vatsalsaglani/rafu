import AppKit

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
