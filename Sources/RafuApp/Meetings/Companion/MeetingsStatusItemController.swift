import AppKit
import Observation
import RafuCore

/// The Meetings item in the menu bar. Made at launch on a Mac that can run
/// Meetings (`MeetingsFeatureFactory.prepareStatusAtLaunch()`), and kept
/// until Rafu quits (`MeetingsStatusSurfaces`).
///
/// The button draws `MeetingsStatusPolicy.statusItem`: a waveform at rest,
/// "● 12:47" while a recording runs, a pause symbol and the time while it
/// is paused, a ring while meetings are processed. It redraws through
/// observation of the session model, and sets the button only when the
/// shown content changed (one time a second while recording).
///
/// A click opens a plain system menu, built from
/// `MeetingsStatusPolicy.menu` each time it opens (`menuNeedsUpdate`), so it
/// is current and works with VoiceOver and the keyboard.
@MainActor
final class MeetingsStatusItemController: NSObject, NSMenuDelegate {
    private let session: MeetingsSessionModel
    private let setting: MeetingsFloatingBarSetting
    private let onFloatingBarSettingChanged: @MainActor () -> Void
    private var statusItem: NSStatusItem?
    private var lastDrawn: MeetingsStatusItemContent?
    /// The actions of the open menu, by item tag.
    private var menuActions: [MeetingsStatusAction] = []

    init(
        session: MeetingsSessionModel, setting: MeetingsFloatingBarSetting,
        onFloatingBarSettingChanged: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.setting = setting
        self.onFloatingBarSettingChanged = onFloatingBarSettingChanged
        super.init()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.behavior = []
        let menu = NSMenu(title: "Meetings")
        menu.autoenablesItems = false
        menu.delegate = self
        item.menu = menu
        if let button = item.button {
            button.imagePosition = .imageLeading
            button.font = Self.font
        }
        statusItem = item
        observe()
    }

    private static var font: NSFont {
        NSFont.monospacedDigitSystemFont(
            ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    /// Takes the item out of the menu bar. The controller is inert after.
    func remove() {
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
    }

    // MARK: Drawing

    /// Draws, then redraws when a value the drawing read changes.
    /// `onChange` fires once, before the change lands, so it re-arms on the
    /// next main-actor turn.
    private func observe() {
        guard statusItem != nil else { return }
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
    }

    private func currentInput() -> MeetingsStatusInput {
        MeetingsStatusActions.input(
            session: session, canOpenWindow: MeetingsWindowOpener.shared.canOpen,
            floatingBarEnabled: setting.isEnabled)
    }

    private func render() {
        let content = MeetingsStatusPolicy.statusItem(currentInput())
        guard content != lastDrawn, let button = statusItem?.button else { return }
        lastDrawn = content
        if let symbol = content.symbolName {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = true
            button.image = image
        } else {
            button.image = nil
        }
        button.attributedTitle = Self.attributedTitle(content.title)
        button.imagePosition =
            content.title.isEmpty
            ? .imageOnly : (content.symbolName == nil ? .noImage : .imageLeading)
        button.toolTip = content.accessibilityLabel
        button.setAccessibilityLabel(content.accessibilityLabel)
    }

    /// Monospaced digits so the item keeps its width each second. The
    /// recording dot is red, and it is also a shape and the word in the
    /// accessibility label, so the state is never colour alone.
    private static func attributedTitle(_ title: String) -> NSAttributedString {
        let text = NSMutableAttributedString(string: title, attributes: [.font: font])
        if title.hasPrefix("●") {
            text.addAttribute(
                .foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: 1))
        }
        return text
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuActions = []
        for value in MeetingsStatusPolicy.menu(currentInput()) {
            if value.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: value.title, action: nil, keyEquivalent: "")
            item.isEnabled = value.isEnabled
            item.state = value.isChecked ? .on : .off
            if let action = value.action {
                item.target = self
                item.action = #selector(runMenuItem(_:))
                item.tag = menuActions.count
                menuActions.append(action)
            }
            menu.addItem(item)
        }
    }

    @objc
    private func runMenuItem(_ sender: NSMenuItem) {
        guard menuActions.indices.contains(sender.tag) else { return }
        MeetingsStatusActions.perform(
            menuActions[sender.tag], session: session,
            toggleFloatingBar: { [setting, onFloatingBarSettingChanged] in
                setting.isEnabled.toggle()
                onFloatingBarSettingChanged()
            })
    }
}
