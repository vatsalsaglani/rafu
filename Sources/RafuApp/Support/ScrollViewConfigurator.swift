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
struct ScrollerHidingConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
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

    private func applyScrollerHiding(to nsView: NSView) {
        guard let scrollView = nsView.enclosingScrollView else { return }
        if scrollView.hasHorizontalScroller {
            scrollView.hasHorizontalScroller = false
        }
        if scrollView.hasVerticalScroller {
            scrollView.hasVerticalScroller = false
        }
    }
}
