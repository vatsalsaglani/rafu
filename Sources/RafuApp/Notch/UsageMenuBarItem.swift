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
/// a transient popover, the menu bar card: the shared
/// `CompanionSectionHost` with Agents, Up next, and Usage. While the card
/// is open, bells land in its Up next feed (`NotchCompanionModel
/// .menuPopoverWillShow()` / `menuPopoverDidClose()`).
@MainActor
final class UsageMenuBarItem: NSObject, NSPopoverDelegate {
    private weak var model: NotchCompanionModel?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
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

    /// The popover content's width and height in points. Each section
    /// scrolls inside it.
    static let popoverSize = NSSize(width: 380, height: 460)

    init(model: NotchCompanionModel) {
        self.model = model
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(
                ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        }
        statusItem = item
        observe()
    }

    /// Takes the item out of the menu bar and closes its popover. The
    /// controller is inert afterwards.
    func remove() {
        popover?.performClose(nil)
        popover = nil
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

    // MARK: - Popover

    @objc
    private func togglePopover(_ sender: Any?) {
        if let popover, popover.isShown {
            popover.performClose(sender)
            return
        }
        showPopover()
    }

    private func showPopover() {
        guard let model, let button = statusItem?.button else { return }
        model.refreshUsage()
        model.menuPopoverWillShow()
        // Built fresh on each open so it picks up the current theme.
        let popover = makePopover(model: model)
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key status lets Escape, the tab shortcuts, and a reply field reach
        // the popover while it is open.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover(model: NotchCompanionModel) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        // The sections use the notch's always-dark ink.
        popover.appearance = NSAppearance(named: .darkAqua)
        let content = UsageMenuBarPopoverView(
            model: model, theme: RafuThemeCatalog.resolvedForCurrentAppearance(),
            close: { [weak popover] in popover?.performClose(nil) })
        let controller = NSHostingController(rootView: content)
        controller.sizingOptions = []
        controller.view.frame = NSRect(origin: .zero, size: Self.popoverSize)
        popover.contentViewController = controller
        popover.contentSize = Self.popoverSize
        return popover
    }

    // MARK: - NSPopoverDelegate

    /// Every close path (a click outside, Escape, the close button, the
    /// status item) ends here, so feed snippets never outlive the card.
    nonisolated func popoverDidClose(_ notification: Notification) {
        let closed = (notification.object as AnyObject?).map(ObjectIdentifier.init)
        MainActor.assumeIsolated {
            // A stale close from an earlier popover never ends a newer one.
            guard closed == nil || closed == popover.map(ObjectIdentifier.init) else { return }
            popover = nil
            model?.menuPopoverDidClose()
        }
    }
}

/// The menu bar card: the shared section host on the notch's black surface.
private struct UsageMenuBarPopoverView: View {
    let model: NotchCompanionModel
    let theme: RafuTheme
    let close: @MainActor () -> Void

    var body: some View {
        let border = RoundedRectangle(
            cornerRadius: CompanionChromeMetrics.popoverBorderRadius, style: .continuous)
        CompanionSectionHost(model: model, host: .menuBar, close: close)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
            // The notch's gradient border, inset inside the popover's own
            // rim: open while shown, a sweep on a new attention event, a
            // slow sweep while an agent works (`CompanionGlowPolicy`).
            .overlay {
                Color.clear
                    .companionGlowBorder(
                        stroke: border, clip: border, visible: true,
                        anyWorking: model.agentSummary.working > 0,
                        attention: model.attentionCount + model.agentSummary.attention
                    )
                    .padding(CompanionChromeMetrics.popoverBorderInset)
                    .allowsHitTesting(false)
            }
            .environment(\.colorScheme, .dark)
            .rafuTheme(theme)
            .onExitCommand { close() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rafu")
            // Pauses the mascot and spinners while the card is hidden or the
            // screen is locked.
            .rafuMotionScope()
    }
}
