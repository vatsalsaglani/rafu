import SwiftUI

/// Captures the hosting `NSWindow` for the SwiftUI view it's attached to, by
/// reading `view.window` once the view is inserted into a window's view
/// hierarchy. SwiftUI has no public API to read a scene's `NSWindow`
/// directly; `WorkspaceSceneRoot` uses this to give `WorkspaceWindowRegistry`
/// a weak reference to each workspace scene's window.
struct WindowAccessor: NSViewRepresentable {
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolve(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolve(from: nsView)
    }

    /// `view.window` is `nil` until AppKit finishes inserting the view into
    /// its window's hierarchy, which hasn't happened yet during
    /// `makeNSView`/`updateNSView` themselves — deferring to the next main
    /// run-loop turn is the standard way to observe it.
    private func resolve(from view: NSView) {
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            onResolve(window)
        }
    }
}
