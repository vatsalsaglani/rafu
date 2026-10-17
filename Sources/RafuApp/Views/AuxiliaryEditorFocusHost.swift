import AppKit
import SwiftUI

/// SwiftUI retains each auxiliary form. This native boundary identifies its
/// responders without inspecting SwiftUI's private view hierarchy.
struct AuxiliaryEditorFocusHost<Content: View>: NSViewRepresentable {
    @Environment(\.self) private var environment
    let isActive: Bool
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        NSHostingView(rootView: hostedContent)
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        if !isActive { AuxiliaryEditorFocusOwnership.resignResponder(in: view) }
        view.rootView = hostedContent
    }

    private var hostedContent: AnyView {
        AnyView(content().environment(\.self, environment).disabled(!isActive))
    }
}

enum AuxiliaryEditorFocusOwnership {
    static func owns(_ responder: NSResponder?, in host: NSView) -> Bool {
        guard let responderView = responder as? NSView else { return false }
        if responderView === host || responderView.isDescendant(of: host) { return true }
        // NSTextField uses the window's shared field editor, which is not a
        // descendant of the text field. Its delegate identifies the owner.
        guard let fieldEditor = responderView as? NSTextView, fieldEditor.isFieldEditor,
            let field = fieldEditor.delegate as? NSView
        else { return false }
        return field === host || field.isDescendant(of: host)
    }

    static func resignResponder(in host: NSView) {
        guard let window = host.window, owns(window.firstResponder, in: host) else { return }
        window.makeFirstResponder(nil)
    }
}
