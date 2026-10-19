import AppKit

/// The editor's scroller, themed to the deck card it sits in.
///
/// Under the legacy scroller style ("Show scroll bars: Always", or
/// "Automatically" with a mouse attached), a stock `NSScroller` paints a
/// neutral system track the full height of the editor along the card's
/// trailing edge, which reads as a grey band breaking the card and squaring
/// its rounded corners. This subclass paints that track in the editor
/// background instead, so only the knob shows. Under the overlay style it
/// keeps the system's translucent hover track (`super`), which floats over
/// the text and never reserves width.
///
/// The scroll view's `scrollerStyle` is never forced: the system resets it
/// when the user's preference or pointing device changes, and AppKit keeps
/// these scroller instances across that change. The knob contrast comes
/// from `NSScrollView.scrollerKnobStyle` (see `apply(to:background:isDark:)`).
final class EditorThemedScroller: NSScroller {
    /// The legacy track colour: the editor background, so the track is the
    /// card's own tone.
    var trackColor: NSColor = .textBackgroundColor {
        didSet {
            guard trackColor != oldValue else { return }
            needsDisplay = true
        }
    }

    /// A subclass that overrides drawing reports itself incompatible with
    /// overlay scrollers by default, which would pin the scroll view to the
    /// legacy style on every Mac. This one only changes the legacy track.
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard scrollerStyle == .legacy else {
            super.drawKnobSlot(in: slotRect, highlight: flag)
            return
        }
        // The whole bounds, not only `slotRect`: the legacy track also draws
        // a separator line on its leading edge, which would still read as a
        // seam against the text.
        trackColor.setFill()
        bounds.fill()
    }

    /// Installs themed scrollers on a fresh editor scroll view. Call before
    /// `hasVerticalScroller`/`hasHorizontalScroller`, so the scroll view
    /// adopts these instead of creating stock ones.
    static func install(in scrollView: NSScrollView) {
        scrollView.verticalScroller = EditorThemedScroller()
        scrollView.horizontalScroller = EditorThemedScroller()
    }

    /// Re-themes the scroll view's scrollers: the legacy track takes the
    /// editor background, and the knob is light on a dark theme and dark on
    /// a light one, for both scroller styles.
    static func apply(to scrollView: NSScrollView, background: NSColor, isDark: Bool) {
        for scroller in [scrollView.verticalScroller, scrollView.horizontalScroller] {
            (scroller as? EditorThemedScroller)?.trackColor = background
        }
        scrollView.scrollerKnobStyle = isDark ? .light : .dark
    }
}
