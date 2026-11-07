import AppKit
import Carbon.HIToolbox

/// Push-to-talk: hold ⌃⌥Space. A Carbon hot key (`RegisterEventHotKey`)
/// reports the press and the release in any app, with no Accessibility
/// permission. A local `NSEvent` monitor stays as the fallback when the
/// registration fails; it sees the key only while Rafu is in front, before
/// any view (a focused terminal card included), and consumes it. Key
/// repeats are ignored.
///
/// macOS uses ⌃⌥Space for "Select next source in Input menu" when more than
/// one input source is on; the system then takes the key first, and neither
/// path sees it. `VoiceHotkeyConflict` detects that for Settings ▸ Voice.
@MainActor
final class VoiceHotkey {
    static let shared = VoiceHotkey()

    /// Space.
    nonisolated static let keyCode: UInt16 = 49
    nonisolated static let modifiers: NSEvent.ModifierFlags = [.control, .option]
    /// "RfVc", the hot key's signature.
    nonisolated static let signature: OSType = 0x5266_5663

    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var isHolding = false
    private weak var session: VoiceSession?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// True when the Carbon hot key is registered, so ⌃⌥Space works in any app.
    private(set) var isGlobal = false

    /// Installs the hot key and the monitor once, at launch. Neither holds a
    /// timer or does work until the key is pressed.
    func install(session: VoiceSession = .shared) {
        guard monitor == nil else { return }
        self.session = session
        isGlobal = registerGlobal()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) {
            [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
        // Without the global key, a release in another app never reaches the
        // local monitor: end the hold when Rafu goes to the back.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isGlobal else { return }
                self.release()
            }
        }
    }

    /// Whether an event is the push-to-talk chord. Pure, for tests.
    nonisolated static func isChord(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        keyCode == Self.keyCode
            && modifiers.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function]) == Self.modifiers
    }

    /// The press of either path. A second press while held is a repeat.
    func press() {
        guard !isHolding else { return }
        isHolding = true
        session?.beginHold()
    }

    func release() {
        guard isHolding else { return }
        isHolding = false
        session?.endHold()
    }

    /// Returns true when the event was the chord and is consumed.
    private func handle(_ event: NSEvent) -> Bool {
        switch event.type {
        case .keyDown:
            guard Self.isChord(keyCode: event.keyCode, modifiers: event.modifierFlags) else {
                return false
            }
            if !event.isARepeat { press() }
            return true
        case .keyUp:
            // The modifiers may already be up; Space alone ends the hold.
            guard event.keyCode == Self.keyCode, isHolding else { return false }
            release()
            return true
        default:
            return false
        }
    }

    // MARK: Carbon hot key

    /// Registers ⌃⌥Space for press and release: the handler on the
    /// application target, the key on the event dispatcher target. Carbon
    /// calls the handler on the main thread.
    private func registerGlobal() -> Bool {
        var specs = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var installed: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(), voiceHotKeyHandler, specs.count, &specs, nil, &installed)
        guard status == noErr, let installed else { return false }
        var registered: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(
            UInt32(kVK_Space), UInt32(controlKey | optionKey), hotKeyID,
            GetEventDispatcherTarget(), 0, &registered)
        guard result == noErr, let registered else {
            RemoveEventHandler(installed)
            return false
        }
        handler = installed
        hotKey = registered
        return true
    }
}

/// The Carbon callback. A closure literal in this main-actor target would
/// infer main-actor isolation and fail the `@convention(c)` conversion, so
/// it is a file-private `nonisolated` function (concurrency.md, FSEvents).
private nonisolated func voiceHotKeyHandler(
    _ next: EventHandlerCallRef?, _ event: EventRef?, _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
        MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
    guard status == noErr, hotKeyID.signature == VoiceHotkey.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    MainActor.assumeIsolated {
        if pressed { VoiceHotkey.shared.press() } else { VoiceHotkey.shared.release() }
    }
    return noErr
}

/// Whether macOS itself owns ⌃⌥Space ("Select next source in Input menu").
/// Pure over the `com.apple.symbolichotkeys` dictionary, for tests.
nonisolated enum VoiceHotkeyConflict {
    /// The symbolic hot key ids for "previous" and "next" input source.
    static let inputSourceIDs = ["60", "61"]
    /// `NSEvent.ModifierFlags` raw values as stored by System Settings.
    static let controlOption = 0x40000 | 0x80000
    static let modifierMask = 0x20000 | 0x40000 | 0x80000 | 0x100000

    /// True when an enabled input-source shortcut is ⌃⌥Space. A missing
    /// "61" entry means the default, which is ⌃⌥Space and enabled.
    static func chordIsTaken(symbolicHotKeys: [String: Any]?) -> Bool {
        let table = symbolicHotKeys ?? [:]
        if table["61"] == nil { return true }
        return inputSourceIDs.contains { id in
            guard let entry = table[id] as? [String: Any],
                (entry["enabled"] as? Bool) ?? ((entry["enabled"] as? Int) == 1),
                let value = entry["value"] as? [String: Any],
                let parameters = value["parameters"] as? [Int], parameters.count >= 3
            else { return false }
            return parameters[1] == Int(VoiceHotkey.keyCode)
                && parameters[2] & modifierMask == controlOption
        }
    }

    /// The live check: the system shortcut is ⌃⌥Space and more than one
    /// keyboard input source can be selected, so the shortcut is active.
    @MainActor
    static func isActive() -> Bool {
        let table =
            CFPreferencesCopyAppValue(
                "AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString)
            as? [String: Any]
        guard chordIsTaken(symbolicHotKeys: table) else { return false }
        let filter =
            [
                kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
                kTISPropertyInputSourceIsSelectCapable as String: true,
            ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue() else {
            return false
        }
        return CFArrayGetCount(list) > 1
    }
}
