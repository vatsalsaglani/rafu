import AppKit
import Observation
import SwiftUI

/// The usage glance as one status item in the menu bar, beside the other
/// apps' items (Settings ▸ General ▸ Notch ▸ Usage glance: "In the menu
/// bar"). Used only on a Dynamic Island Mac, where macOS gives every hover
/// and tap near the island to the system island
/// (`CompanionPresence`). `NotchCompanionModel.activateIfEnabled()` creates
/// and removes it.
///
/// The button shows the most constrained usage window
/// (`NotchCompanionModel.islandUsageGlance`): a ring image and the percent
/// as the button title, so the system draws the text in the menu bar's own
/// colour. When agents need the person, the count joins the title
/// (`"42% · 2"`) and a dot joins the ring, so attention never rests on
/// colour alone (`CompanionMenuBarItemText`). It redraws through
/// observation of the model, never on a timer.
///
/// A click (or a touch-screen tap, which macOS delivers as a click) toggles
/// the menu bar card: a borderless panel that hangs from the status item
/// with concave shoulders (`CompanionMenuPanel`), holding the shared
/// `CompanionSectionHost` with Agents, Up next, Usage, and Meetings. It closes on the
/// same triggers as a transient popover (`CompanionMenuPanelClosePolicy`).
/// While the card is open, bells land in its Up next feed
/// (`NotchCompanionModel.menuPopoverWillShow()` / `menuPopoverDidClose()`;
/// the model keeps the popover names).
@MainActor
final class UsageMenuBarItem: NSObject {
    private weak var model: NotchCompanionModel?
    private var statusItem: NSStatusItem?
    /// The open card, or `nil` while it is closed. A closing card is
    /// already `nil` here while it fades out.
    private var panel: CompanionMenuPanel?
    private var reveal: CompanionMenuPanelReveal?
    private var globalClickMonitor: Any?
    private var localClickMonitor: Any?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    /// The last drawn state, so an unrelated model change never re-renders
    /// the image.
    private var lastDrawn: Drawn?

    private struct Drawn: Equatable {
        let glance: NotchIslandUsageGlance?
        let attention: Int
        let palette: UsageRingPalette
        let isDarkTheme: Bool
        let ringSize: CGFloat
    }

    init(model: NotchCompanionModel) {
        self.model = model
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(toggleCard(_:))
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        statusItem = item
        observe()
    }

    /// Takes the item out of the menu bar and closes its card. The
    /// controller is inert afterwards.
    func remove() {
        closeCard(.removed)
        if model?.isMenuPopoverShown == true { model?.menuPopoverDidClose() }
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: - Drawing

    /// Draws once, then redraws when anything the drawing read changes.
    /// `onChange` fires once per registration, before the change lands, so
    /// it re-arms on the next main-actor turn.
    private func observe() {
        guard statusItem != nil else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func render() {
        guard let model, let button = statusItem?.button else { return }
        let glance = model.islandUsageGlance
        let attention = model.upNextRows(for: .menuBar).count
        let palette = model.usageRingPalette
        let theme = RafuThemeCatalog.resolvedForCurrentAppearance()
        let ringSize = UsageMenuBarItemText.ringSize(
            forBarThickness: NSStatusBar.system.thickness)
        let drawn = Drawn(
            glance: glance, attention: attention, palette: palette, isDarkTheme: theme.isDark,
            ringSize: ringSize)
        guard drawn != lastDrawn else { return }
        lastDrawn = drawn

        let title = CompanionMenuBarItemText.title(glance: glance, attention: attention)
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.image = Self.ringImage(
            glance: glance, attention: attention > 0, palette: palette, theme: theme,
            size: ringSize,
            scale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let label = CompanionMenuBarItemText.accessibilityLabel(
            glance: glance, attention: attention)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// The ring as an image. Monochrome is a template image, so the menu bar
    /// tints it like the system's own glyphs on a light or dark bar. Colour
    /// keeps the theme's stable ring hue, with its own tinted track. With
    /// `attention`, a filled dot sits at one o'clock: a shape, so it still
    /// reads in a template image.
    private static func ringImage(
        glance: NotchIslandUsageGlance?, attention: Bool, palette: UsageRingPalette,
        theme: RafuTheme, size: CGFloat, scale: CGFloat
    ) -> NSImage? {
        let arc: RafuProgressRing.Arc
        let dotColor: Color
        switch palette {
        case .monochrome:
            arc = RafuProgressRing.Arc(
                fraction: glance?.fraction, color: .black, track: .black.opacity(0.3))
            dotColor = .black
        case .color:
            let ink = UsageCardInk.notch(theme: theme, palette: .color)
            arc = RafuProgressRing.Arc(
                fraction: glance?.fraction, color: ink.color(for: glance?.tone ?? .primary),
                track: nil)
            dotColor = theme.palette.accent
        }
        let dot = max(4, (size * 0.36).rounded())
        let ring = RafuProgressRing(arcs: [arc], size: size, lineWidth: 2.5, gap: 0)
            .overlay(alignment: .topTrailing) {
                if attention {
                    Circle()
                        .fill(dotColor)
                        .frame(width: dot, height: dot)
                        .offset(x: dot * 0.25, y: -dot * 0.25)
                }
            }
            .padding(1)
        let renderer = ImageRenderer(content: ring)
        renderer.scale = scale
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = palette == .monochrome
        return image
    }

    // MARK: - Card panel

    @objc
    private func toggleCard(_ sender: Any?) {
        if panel != nil {
            closeCard(.statusItemToggled)
            return
        }
        showCard()
    }

    /// The status item's window frame in screen coordinates: the approval
    /// peek hangs below it. `nil` when macOS hid the item (no window, or a
    /// window off every screen).
    var anchorFrame: CGRect? {
        guard let window = statusItem?.button?.window, window.isVisible,
            let screen = window.screen
        else { return nil }
        let frame = window.frame
        return screen.frame.intersects(frame) ? frame : nil
    }

    /// Opens the card if it is closed (a `rafu://usage` widget link). An
    /// open card stays open.
    func revealCard() {
        if panel != nil { return }
        showCard()
    }

    private func showCard() {
        guard let model, let button = statusItem?.button, let anchorWindow = button.window,
            let frame = CompanionMenuPanelGeometry.frame(
                anchor: anchorWindow.frame, screens: Self.screens())
        else { return }
        model.refreshUsage()
        model.menuPopoverWillShow()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // Built fresh on each open so it picks up the current theme.
        let reveal = CompanionMenuPanelReveal(progress: reduceMotion ? 1 : 0)
        let panel = CompanionMenuPanel(contentRect: frame)
        panel.onCancel = { [weak self] in self?.closeCard(.escape) }
        let content = CompanionMenuPanelView(
            model: model, theme: RafuThemeCatalog.resolvedForCurrentAppearance(), reveal: reveal,
            close: { [weak self] in self?.closeCard(.closeButton) })
        let hostingView = NotchHUDPassthroughHostingView(rootView: content)
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: frame.size)
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        // Beside a shoulder the card takes no click: it goes to what is
        // behind, as the outline draws.
        hostingView.hitOutline = CompanionMenuPanelGeometry.outline
        self.panel = panel
        self.reveal = reveal
        installCloseTriggers(for: panel)
        // Key status lets Escape, the tab shortcuts, the arrows, and a reply
        // field reach the card. The panel is non-activating, so Rafu does
        // not come forward and the Dock and the menu bar do not change.
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration =
                    reduceMotion
                    ? CompanionMenuPanelReveal.reducedFadeDuration
                    : CompanionMenuPanelReveal.fadeDuration
                panel.animator().alphaValue = 1
            },
            completionHandler: { [weak panel] in
                // The shadow follows the drawn outline once the fade ends.
                Task { @MainActor [weak panel] in panel?.invalidateShadow() }
            })
    }

    /// Closes the card for `event` when the close rules say so. Every close
    /// path ends here, so feed snippets never outlive the card (ADR 0016).
    private func closeCard(_ event: CompanionMenuPanelCloseEvent) {
        guard CompanionMenuPanelClosePolicy.closes(on: event), let panel else { return }
        removeCloseTriggers()
        self.panel = nil
        let reveal = self.reveal
        self.reveal = nil
        model?.menuPopoverDidClose()
        panel.onCancel = nil
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if event == .removed {
            panel.orderOut(nil)
        } else {
            if !reduceMotion, let reveal {
                withAnimation(CompanionMenuPanelReveal.closeAnimation) { reveal.progress = 0 }
            }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration =
                        reduceMotion
                        ? CompanionMenuPanelReveal.reducedFadeDuration
                        : CompanionMenuPanelReveal.fadeDuration
                    panel.animator().alphaValue = 0
                },
                completionHandler: {
                    // Each open builds its own panel, so this old one never
                    // hides a newer card.
                    Task { @MainActor in panel.orderOut(nil) }
                })
        }
        returnAccessibilityFocus()
    }

    /// VoiceOver goes back to the status item, as when a popover closes.
    private func returnAccessibilityFocus() {
        guard NSWorkspace.shared.isVoiceOverEnabled, let button = statusItem?.button else {
            return
        }
        NSAccessibility.post(
            element: button, notification: .layoutChanged,
            userInfo: [.uiElements: [button]])
    }

    private static func screens() -> [CompanionMenuPanelScreen] {
        NSScreen.screens.map {
            CompanionMenuPanelScreen(frame: $0.frame, visibleFrame: $0.visibleFrame)
        }
    }

    // MARK: - Close triggers

    /// The triggers a transient popover closes on: a click outside (in
    /// another app, the desktop, or another Rafu window), a lost key
    /// status, a Space change, a locked screen, or a session switch. The
    /// click handlers read only the event's window number, never its
    /// location or keys.
    private func installCloseTriggers(for panel: CompanionMenuPanel) {
        let mouseDown: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseDown) {
            [weak self] _ in
            // Global monitor handlers run on the main thread.
            MainActor.assumeIsolated { self?.handleClick(windowNumber: nil, isGlobal: true) }
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseDown) {
            [weak self] event in
            let windowNumber = event.window?.windowNumber
            MainActor.assumeIsolated {
                self?.handleClick(windowNumber: windowNumber, isGlobal: false)
            }
            return event
        }
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed: NotificationCenter = DistributedNotificationCenter.default()
        observers = [
            (
                center,
                center.addObserver(
                    forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeCard(.resignedKey) }
                }
            ),
            (
                center,
                center.addObserver(
                    forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.repositionCard() }
                }
            ),
            (
                workspace,
                workspace.addObserver(
                    forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeCard(.activeSpaceChanged) }
                }
            ),
            (
                workspace,
                workspace.addObserver(
                    forName: NSWorkspace.sessionDidResignActiveNotification, object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeCard(.screenLocked) }
                }
            ),
            (
                distributed,
                distributed.addObserver(
                    forName: Notification.Name("com.apple.screenIsLocked"), object: nil,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.closeCard(.screenLocked) }
                }
            ),
        ]
    }

    private func removeCloseTriggers() {
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        globalClickMonitor = nil
        localClickMonitor = nil
        for (center, token) in observers { center.removeObserver(token) }
        observers = []
    }

    private func handleClick(windowNumber: Int?, isGlobal: Bool) {
        guard let panel else { return }
        let target = CompanionMenuPanelClosePolicy.clickTarget(
            isGlobal: isGlobal, eventWindowNumber: windowNumber,
            panelWindowNumber: panel.windowNumber,
            statusItemWindowNumber: statusItem?.button?.window?.windowNumber)
        closeCard(.mouseDown(target))
    }

    /// A display change moves the card back under the status item.
    private func repositionCard() {
        guard let panel, let anchor = statusItem?.button?.window?.frame,
            let frame = CompanionMenuPanelGeometry.frame(anchor: anchor, screens: Self.screens())
        else { return }
        panel.setFrame(frame, display: true)
    }
}
