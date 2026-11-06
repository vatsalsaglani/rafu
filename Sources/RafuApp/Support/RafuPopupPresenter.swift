import AppKit
import SwiftUI

/// Presents Rafu popups (ADR 0033) as sheets on the workspace window for
/// callers that have no SwiftUI host: model code and `Task` bodies. A view
/// uses `.sheet` with the popup components instead.
@MainActor
enum RafuPopupPresenter {
    /// The workspace window a sheet attaches to. The Icon Library panel can
    /// be the key window; a sheet never attaches to it.
    static func parentWindow() -> NSWindow? {
        [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }.first { !($0 is NSPanel) }
    }

    static func presentSheet<Content: View>(
        size: NSSize, @ViewBuilder content: (@escaping () -> Void) -> Content
    ) {
        guard let parent = parentWindow() else { return }
        let sheet = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled],
            backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        let dismiss: () -> Void = { [weak parent, weak sheet] in
            guard let sheet else { return }
            if let parent { parent.endSheet(sheet) } else { sheet.close() }
        }
        sheet.contentViewController = NSHostingController(
            rootView: content(dismiss)
                .rafuTheme(RafuThemeCatalog.resolvedForCurrentAppearance())
                .rafuMotionScope())
        parent.beginSheet(sheet)
    }

    /// Shows an error or information message in a Rafu popup sheet on the
    /// workspace window. When every window is gone there is no sheet
    /// parent; then one system alert shows the message, so the user always
    /// sees the error.
    static func presentMessage(
        kind: RafuMessagePopup.Kind = .error, title: String, message: String
    ) {
        guard parentWindow() != nil else {
            presentFallbackAlert(title: title, message: message)
            return
        }
        presentSheet(size: NSSize(width: 420, height: 180)) { dismiss in
            RafuMessagePopup(kind: kind, title: title, message: message, dismiss: dismiss)
        }
    }

    private static func presentFallbackAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Resumes a continuation once. A popup can report through its button and
/// again through Escape; only the first answer counts.
@MainActor
final class CanvasPopupAnswer {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
