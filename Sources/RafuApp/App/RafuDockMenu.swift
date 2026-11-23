import AppKit

/// The Dock icon's menu (right-click on Rafu in the Dock): New Window,
/// Open Meetings, and Start or Stop Recording. AppKit adds the window list,
/// Options, Show All Windows, Hide and Quit below it.
///
/// The window items use the `openWindow` actions that the SwiftUI windows
/// capture (`WorkspaceWindowRegistry`, `MeetingsWindowOpener`). An item is
/// not shown when no window gave its action yet.
@MainActor
final class RafuDockMenu: NSObject {
    static let shared = RafuDockMenu()

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item("New Window", #selector(newWindow)))

        let factory = MeetingsFeatureFactory.shared
        guard factory.availability.isAvailable, MeetingsWindowOpener.shared.canOpen else {
            return menu
        }
        menu.addItem(.separator())
        menu.addItem(item("Open Meetings", #selector(openMeetings)))
        let state = MeetingsMenuState(
            isAvailable: true, session: factory.feature?.session)
        let record = item(state.recordTitle, #selector(toggleRecording))
        record.isEnabled = state.isRecordEnabled
        menu.addItem(record)
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func newWindow() {
        NSApp.activate()
        WorkspaceWindowRegistry.shared.openWorkspaceWindow()
    }

    @objc private func openMeetings() {
        MeetingsWindowOpener.shared.open()
    }

    /// The same rule as Meetings ▸ Start/Stop Recording: Stop reads the
    /// existing feature; Start makes it, opens the window, then starts.
    @objc private func toggleRecording() {
        let factory = MeetingsFeatureFactory.shared
        let state = MeetingsMenuState(isAvailable: true, session: factory.feature?.session)
        if state.recordStops {
            factory.feature?.session.stop()
            return
        }
        let feature = factory.resolve()
        guard feature.availability.isAvailable, feature.session.canStartRecording else { return }
        MeetingsWindowOpener.shared.open()
        feature.session.startRecording()
    }
}
