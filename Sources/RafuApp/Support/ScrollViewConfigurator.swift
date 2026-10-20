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

/// Gives ONE sidebar `List`'s `NSScrollView` overlay scrollers that float
/// over the rows, with a knob that contrasts with the theme (design polish
/// round 4). Under "Show scroll bars: Always" a `List` otherwise draws a
/// legacy 15 pt scroller with a neutral system track that clashes with the
/// sidebar tone and pushes the row pills off-centre. The vertical scroller
/// stays enabled, so the list still shows where it is while scrolling.
///
/// Per scroll view only: this never touches `NSScroller`'s global preferred
/// style, and the editor keeps `EditorThemedScroller`, which follows the
/// user's system preference.
///
/// Attach it as `.background(OverlayScrollerConfigurator(...))` on the
/// `List` itself. A `List` has no single content view to host a probe the
/// way `ScrollerHidingConfigurator` does, so the probe finds the scroll view
/// that contains its own centre, searching outward from its parent, and
/// never looks inside another scroll view (an editor's text, for example).
struct OverlayScrollerConfigurator: NSViewRepresentable {
    var knobStyle: NSScroller.KnobStyle

    func makeNSView(context: Context) -> OverlayScrollerProbeView {
        let view = OverlayScrollerProbeView(frame: .zero)
        view.knobStyle = knobStyle
        return view
    }

    func updateNSView(_ nsView: OverlayScrollerProbeView, context: Context) {
        nsView.knobStyle = knobStyle
        nsView.apply()
    }
}

/// Zero-content probe beside a `List`; see `OverlayScrollerConfigurator`.
final class OverlayScrollerProbeView: NSView {
    var knobStyle: NSScroller.KnobStyle = .default
    private weak var scrollView: NSScrollView?
    private var preferenceObserver: NSObjectProtocol?

    /// How many ancestors the search climbs before it gives up.
    private static let maximumAncestorLevels = 6

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scrollView = nil
        if window == nil {
            stopObservingPreference()
        } else {
            observePreference()
            apply()
        }
    }

    override func layout() {
        super.layout()
        apply()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Only writes a property that differs, so a re-apply from `layout()`
    /// never invalidates the scroll view's layout again.
    func apply() {
        guard let scrollView = resolveScrollView() else { return }
        if scrollView.scrollerStyle != .overlay {
            scrollView.scrollerStyle = .overlay
        }
        if !scrollView.autohidesScrollers {
            scrollView.autohidesScrollers = true
        }
        if scrollView.scrollerKnobStyle != knobStyle {
            scrollView.scrollerKnobStyle = knobStyle
        }
    }

    /// AppKit resets every scroll view's style when the user's scroller
    /// preference (or pointing device) changes. Re-apply one turn later, so
    /// this runs after AppKit's own reset.
    private func observePreference() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.apply()
            }
        }
    }

    private func stopObservingPreference() {
        if let preferenceObserver {
            NotificationCenter.default.removeObserver(preferenceObserver)
        }
        preferenceObserver = nil
    }

    private func resolveScrollView() -> NSScrollView? {
        if let scrollView, scrollView.window != nil, scrollView.window === window {
            return scrollView
        }
        guard window != nil, bounds.width > 0, bounds.height > 0 else { return nil }
        let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
        var ancestor = superview
        var level = 0
        while let current = ancestor, level < Self.maximumAncestorLevels {
            if let found = Self.scrollView(in: current, containing: centre) {
                scrollView = found
                return found
            }
            ancestor = current.superview
            level += 1
        }
        return nil
    }

    /// Breadth-first, so the nearest scroll view wins; never descends into a
    /// scroll view, so nested ones (an editor, a text field) are skipped.
    private static func scrollView(in root: NSView, containing point: NSPoint) -> NSScrollView? {
        var queue: [NSView] = [root]
        var index = 0
        while index < queue.count {
            let view = queue[index]
            index += 1
            if let scrollView = view as? NSScrollView {
                if scrollView.convert(scrollView.bounds, to: nil).contains(point) {
                    return scrollView
                }
                continue
            }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
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
