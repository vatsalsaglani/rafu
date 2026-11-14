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
/// colour. It redraws through observation of the model, never on a timer.
/// A click (or a touch-screen tap, which macOS delivers as a click) toggles
/// a transient popover with the Usage section.
@MainActor
final class UsageMenuBarItem: NSObject {
    private weak var model: NotchCompanionModel?
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// The last drawn state, so an unrelated model change never re-renders
    /// the image.
    private var lastDrawn: Drawn?

    private struct Drawn: Equatable {
        let glance: NotchIslandUsageGlance?
        let palette: UsageRingPalette
        let isDarkTheme: Bool
        let ringSize: CGFloat
    }

    /// The popover content's width and height in points.
    private static let popoverSize = NSSize(width: 360, height: 380)

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
        let palette = model.usageRingPalette
        let theme = RafuThemeCatalog.resolvedForCurrentAppearance()
        let ringSize = UsageMenuBarItemText.ringSize(
            forBarThickness: NSStatusBar.system.thickness)
        let drawn = Drawn(
            glance: glance, palette: palette, isDarkTheme: theme.isDark, ringSize: ringSize)
        guard drawn != lastDrawn else { return }
        lastDrawn = drawn

        let title = UsageMenuBarItemText.title(for: glance)
        button.title = title
        button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        button.image = Self.ringImage(
            glance: glance, palette: palette, theme: theme, size: ringSize,
            scale: button.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let label = UsageMenuBarItemText.accessibilityLabel(for: glance)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// The ring as an image. Monochrome is a template image, so the menu bar
    /// tints it like the system's own glyphs on a light or dark bar. Colour
    /// keeps the theme's stable ring hue, with its own tinted track.
    private static func ringImage(
        glance: NotchIslandUsageGlance?, palette: UsageRingPalette, theme: RafuTheme,
        size: CGFloat, scale: CGFloat
    ) -> NSImage? {
        let arc: RafuProgressRing.Arc
        switch palette {
        case .monochrome:
            arc = RafuProgressRing.Arc(
                fraction: glance?.fraction, color: .black, track: .black.opacity(0.3))
        case .color:
            let ink = UsageCardInk.notch(theme: theme, palette: .color)
            arc = RafuProgressRing.Arc(
                fraction: glance?.fraction, color: ink.color(for: glance?.tone ?? .primary),
                track: nil)
        }
        let ring = RafuProgressRing(arcs: [arc], size: size, lineWidth: 2.5, gap: 0)
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
        // Built fresh on each open so it picks up the current theme.
        let popover = makePopover(model: model)
        self.popover = popover
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Key status lets Escape reach the popover while it is open.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover(model: NotchCompanionModel) -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        // The Usage cards use the notch's always-dark ink.
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
}

/// The status item's popover: the companion's Usage section on the notch's
/// black surface, with no tab row. The section scrolls when it is taller
/// than the popover.
private struct UsageMenuBarPopoverView: View {
    let model: NotchCompanionModel
    let theme: RafuTheme
    let close: @MainActor () -> Void

    var body: some View {
        CompanionUsageSectionView(model: model, onClose: close)
            .padding(.top, RafuMetrics.space2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
            .rafuTheme(theme)
            .onExitCommand { close() }
    }
}
