import AppKit
import Observation
import SwiftUI

// The menu bar card's window (ADR 0037, Phase B): a borderless panel that
// hangs from the usage status item with concave shoulders at its top edge,
// in place of the system popover and its arrow and rim. The geometry and
// the close rules are pure values, so tests cover them without a window.

// MARK: - Geometry

/// One screen as the menu bar card sees it, in AppKit screen coordinates
/// (bottom-left origin, y up).
nonisolated struct CompanionMenuPanelScreen: Equatable, Sendable {
    let frame: CGRect
    let visibleFrame: CGRect
}

/// Where the menu bar card goes. Pure: AppKit values in, a frame out.
nonisolated enum CompanionMenuPanelGeometry {
    /// The card's content: each section scrolls inside it.
    static let contentSize = CGSize(width: 380, height: 460)
    /// The outline: Cider's open notch outline, concave shoulders at the
    /// top edge (against the menu bar) and round bottom corners.
    static let outline = CompanionOutlineLimits.open
    /// The least space between the card body and a screen side, or the
    /// bottom of the visible frame (the Dock).
    static let screenMargin: CGFloat = 8
    /// The height the card grows from when it opens: three shoulders, so
    /// the shoulders show at full size from the first frame.
    static var collapsedHeight: CGFloat { outline.shoulder * 3 }

    /// The panel's full size: the content plus one shoulder at each side.
    static var panelSize: CGSize {
        CGSize(width: contentSize.width + 2 * outline.shoulder, height: contentSize.height)
    }

    /// The screen that shows the status item `anchor`: the one that holds
    /// its centre, else the one it overlaps most, else the first.
    static func screen(for anchor: CGRect, among screens: [CompanionMenuPanelScreen])
        -> CompanionMenuPanelScreen?
    {
        let centre = CGPoint(x: anchor.midX, y: anchor.midY)
        if let holder = screens.first(where: { $0.frame.contains(centre) }) { return holder }
        let overlaps = screens.map { screen -> CGFloat in
            let overlap = screen.frame.intersection(anchor)
            return overlap.isNull ? 0 : overlap.width * overlap.height
        }
        if let best = overlaps.indices.max(by: { overlaps[$0] < overlaps[$1] }), overlaps[best] > 0
        {
            return screens[best]
        }
        return screens.first
    }

    /// The panel frame under the status item `anchor` (the status item
    /// button's window frame, which spans the menu bar's height).
    ///
    /// The top edge sits on the bottom of the menu bar: the anchor's bottom,
    /// never above the visible frame's top (45 pt below the screen top on a
    /// Dynamic Island Mac, 37 pt on a notched Mac, 24 pt on most external
    /// displays). With an auto-hidden or full-screen menu bar the visible
    /// frame reaches the screen top, and the anchor's bottom still marks the
    /// shown bar. The card centres on the item and keeps its body
    /// `screenMargin` inside the visible frame's sides; a shoulder may reach
    /// nearer the edge but never past the screen. On a short screen the card
    /// is shorter, and its sections scroll.
    static func frame(
        anchor: CGRect, screen: CompanionMenuPanelScreen, contentSize: CGSize = contentSize
    ) -> CGRect {
        let shoulder = outline.shoulder
        let visible = screen.visibleFrame
        let anchorInside = anchor.minY > visible.minY && anchor.minY <= screen.frame.maxY
        let top = anchorInside ? min(anchor.minY, visible.maxY) : visible.maxY
        let available = max(0, top - visible.minY - screenMargin)
        let height = min(contentSize.height, available)
        let width = contentSize.width + 2 * shoulder

        var minX = visible.minX + screenMargin - shoulder
        var maxX = visible.maxX - screenMargin + shoulder - width
        minX = max(minX, screen.frame.minX)
        maxX = min(maxX, screen.frame.maxX - width)
        var x = anchor.midX - width / 2
        if minX <= maxX {
            x = min(max(x, minX), maxX)
        } else {
            // Narrower than the card: centre it on the screen.
            x = screen.frame.midX - width / 2
        }
        return CGRect(x: x, y: top - height, width: width, height: height)
    }

    /// The panel frame for `anchor` among `screens`, or `nil` with no screen.
    static func frame(anchor: CGRect, screens: [CompanionMenuPanelScreen]) -> CGRect? {
        screen(for: anchor, among: screens).map { frame(anchor: anchor, screen: $0) }
    }
}

// MARK: - Close rules

/// Where a mouse-down went while the card is open.
nonisolated enum CompanionMenuPanelClickTarget: Equatable, Sendable {
    /// Inside the card.
    case panel
    /// The usage status item. Its own action toggles the card, so the click
    /// monitor leaves it alone (else the card would close and reopen).
    case statusItem
    /// Another Rafu window.
    case otherRafuWindow
    /// Another app, the desktop, or the system menu bar.
    case otherApp
}

/// Something that may close the card.
nonisolated enum CompanionMenuPanelCloseEvent: Equatable, Sendable {
    case mouseDown(CompanionMenuPanelClickTarget)
    /// Escape, from the panel or the SwiftUI content.
    case escape
    /// The status item clicked again while the card is open.
    case statusItemToggled
    /// The card's own close button.
    case closeButton
    /// Mission Control or a swipe moved to another Space.
    case activeSpaceChanged
    /// The screen locked, or the user session switched away.
    case screenLocked
    /// The card lost key status (another app or Rafu window took it).
    case resignedKey
    /// The status item left the menu bar.
    case removed
}

/// The pure close rules: the same set of triggers as a transient popover.
nonisolated enum CompanionMenuPanelClosePolicy {
    static func closes(on event: CompanionMenuPanelCloseEvent) -> Bool {
        switch event {
        case .mouseDown(.panel), .mouseDown(.statusItem): false
        case .mouseDown(.otherRafuWindow), .mouseDown(.otherApp): true
        case .escape, .statusItemToggled, .closeButton, .activeSpaceChanged, .screenLocked,
            .resignedKey, .removed:
            true
        }
    }

    /// Classifies a mouse-down from a click monitor. A global monitor sees
    /// only events that go to other apps; a local one sees Rafu's own, with
    /// the window number of the window the event goes to.
    static func clickTarget(
        isGlobal: Bool, eventWindowNumber: Int?, panelWindowNumber: Int?,
        statusItemWindowNumber: Int?
    ) -> CompanionMenuPanelClickTarget {
        if isGlobal { return .otherApp }
        guard let eventWindowNumber else { return .otherApp }
        if eventWindowNumber == panelWindowNumber { return .panel }
        if eventWindowNumber == statusItemWindowNumber { return .statusItem }
        return .otherRafuWindow
    }
}

// MARK: - Reveal

/// The card's open and close morph: 0 is the collapsed nub against the menu
/// bar, 1 is the full card. Under Reduce Motion it jumps.
@Observable
final class CompanionMenuPanelReveal {
    var progress: CGFloat

    init(progress: CGFloat = 0) {
        self.progress = progress
    }

    static let openAnimation: Animation = .spring(response: 0.28, dampingFraction: 0.9)
    static let closeAnimation: Animation = .easeIn(duration: fadeDuration)
    /// The window fade with the morph, on open and on close.
    static let fadeDuration: TimeInterval = 0.14
    /// The window fade under Reduce Motion, which replaces the morph.
    static let reducedFadeDuration: TimeInterval = 0.12
}

/// The companion outline cut to the reveal: the same top edge and
/// shoulders, with the bottom at `progress` between the collapsed height
/// and the full height. At 1 it is exactly `CompanionOutline`.
nonisolated struct CompanionMenuRevealShape: Shape {
    var progress: CGFloat
    var openTop = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        Path(
            CompanionOutline.cgPath(
                in: Self.revealedRect(in: rect, progress: progress),
                limits: CompanionMenuPanelGeometry.outline, openTop: openTop))
    }

    /// The top part of `rect` the outline covers at `progress`.
    static func revealedRect(in rect: CGRect, progress: CGFloat) -> CGRect {
        let collapsed = min(CompanionMenuPanelGeometry.collapsedHeight, rect.height)
        let clamped = min(max(progress, 0), 1)
        let height = collapsed + (rect.height - collapsed) * clamped
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: height)
    }
}

// MARK: - Window

/// The card's borderless, non-activating panel. It can become key, so a
/// reply field, the tab shortcuts, the arrows, and Escape reach it, but it
/// never activates Rafu: key status goes back to the front app when it
/// closes, as with the system popover.
final class CompanionMenuPanel: NSPanel {
    /// Escape forwards here from AppKit's `cancelOperation`.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Above the menu bar and the notch companion, as a menu.
        level = .popUpMenu
        // Shows over a full-screen app, in the active Space only; the card
        // closes on a Space change. Not in Mission Control or the window
        // cycle.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
        isFloatingPanel = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)
        // VoiceOver: a dialog named Rafu, as the popover was announced.
        title = "Rafu"
        setAccessibilitySubrole(.dialog)
        setAccessibilityLabel("Rafu")
    }

    /// Keeps the frame where the pure geometry put it: it is already
    /// clamped to the screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// The menu bar card: the shared section host on the notch's black surface,
/// inside the companion outline. The fill, the clip, and the gradient border
/// use one path; the panel's hit test uses the same outline
/// (`NotchHUDPassthroughHostingView.hitOutline`).
struct CompanionMenuPanelView: View {
    let model: NotchCompanionModel
    let theme: RafuTheme
    let reveal: CompanionMenuPanelReveal
    let close: @MainActor () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let surface = CompanionMenuRevealShape(progress: reveal.progress)
        CompanionSectionHost(model: model, host: .menuBar, close: close)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, CompanionMenuPanelGeometry.outline.shoulder)
            .background(Color.black, in: surface)
            // The notch's gradient border along the outline: open while
            // shown, a sweep on a new attention event, a slow sweep while an
            // agent works (`CompanionGlowPolicy`). The top edge sits against
            // the menu bar, so the stroke leaves it out.
            .companionGlowBorder(
                stroke: CompanionMenuRevealShape(progress: reveal.progress, openTop: true),
                clip: surface, visible: true,
                anyWorking: model.agentSummary.working > 0,
                attention: model.attentionCount + model.agentSummary.attention
            )
            .clipShape(surface)
            .environment(\.colorScheme, .dark)
            .rafuTheme(theme)
            .onExitCommand { close() }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Rafu")
            .onAppear {
                guard reveal.progress < 1 else { return }
                if reduceMotion {
                    reveal.progress = 1
                } else {
                    withAnimation(CompanionMenuPanelReveal.openAnimation) { reveal.progress = 1 }
                }
            }
            // Pauses the mascot and spinners while the card is hidden or the
            // screen is locked.
            .rafuMotionScope()
    }
}
