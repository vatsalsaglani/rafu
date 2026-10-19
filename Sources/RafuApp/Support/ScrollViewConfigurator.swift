import AppKit
import SwiftUI

/// Forces the enclosing `NSScrollView`'s legacy (non-overlay) scrollers off.
///
/// SwiftUI's `.scrollIndicators(.hidden)` only hides the OVERLAY indicator
/// SwiftUI itself draws. When System Settings → Appearance → "Show scroll
/// bars" is set to "Always", AppKit's underlying `NSScrollView` keeps
/// `hasHorizontalScroller`/`hasVerticalScroller` `true` regardless and still
/// draws a legacy, non-overlay `NSScroller` — `.scrollIndicators(.hidden)`
/// cannot suppress that. See
/// `docs/references/scrollview-legacy-scroller-always-setting.md` for the
/// full nuance writeup.
///
/// Attach this as a zero-size `.background` (falling back to `.overlay` if
/// `.background` does not resolve the hierarchy) on the CONTENT view placed
/// INSIDE a `ScrollView`, not on the `ScrollView` itself — only the content
/// view's `enclosingScrollView` is guaranteed to be the scroll view once the
/// hierarchy is attached.
///
/// It also forces the overlay scroller style: a legacy-style scroll view
/// reserves a scroller's height below its content, which made the tab shelf
/// grow by about 15 pt the moment the tabs overflowed. The probe view
/// re-applies on every attach and resize (the content view resizes exactly
/// when the row starts to overflow), because AppKit resets the style when
/// the system scroller preference changes.
struct ScrollerHidingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = ScrollerHidingProbeView(frame: .zero)
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        applyScrollerHiding(to: nsView)
        // `enclosingScrollView` may not resolve yet on the update pass that
        // first attaches this view to the hierarchy (e.g. first layout after
        // a tab bar appears); re-apply once more on the next run-loop turn
        // so it is caught either way without polling indefinitely.
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            applyScrollerHiding(to: nsView)
        }
    }
}

/// Zero-content probe inside the scrolled content; see
/// `ScrollerHidingConfigurator`.
private final class ScrollerHidingProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScrollerHiding(to: self)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        applyScrollerHiding(to: self)
    }

    override func layout() {
        super.layout()
        applyScrollerHiding(to: self)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Only writes a property that differs, so a re-apply from `layout()` never
/// invalidates the scroll view's layout again.
@MainActor
private func applyScrollerHiding(to view: NSView) {
    guard let scrollView = view.enclosingScrollView else { return }
    if scrollView.scrollerStyle != .overlay {
        scrollView.scrollerStyle = .overlay
    }
    if !scrollView.autohidesScrollers {
        scrollView.autohidesScrollers = true
    }
    if scrollView.hasHorizontalScroller {
        scrollView.hasHorizontalScroller = false
    }
    if scrollView.hasVerticalScroller {
        scrollView.hasVerticalScroller = false
    }
}
