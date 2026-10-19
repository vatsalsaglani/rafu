import AppKit
import SwiftUI

/// The system states that decide whether anybody can see the screen. Pure
/// and `Sendable`, so the rule is testable without notifications.
nonisolated struct RafuMotionConditions: Equatable, Sendable {
    var screenLocked = false
    var displaysAsleep = false
    /// Fast user switching moved the console to another user.
    var sessionInactive = false

    enum Event: Equatable, Sendable {
        case screenLocked, screenUnlocked
        case displaysSlept, displaysWoke
        case sessionResignedActive, sessionBecameActive
    }

    /// Nobody can see any Rafu window: the screen is locked, the displays
    /// sleep, or another user has the console.
    var isScreenActive: Bool { !screenLocked && !displaysAsleep && !sessionInactive }

    /// Whether continuous motion may run in one window. `windowVisible` is
    /// that window's occlusion state (`NSWindow.OcclusionState.visible`).
    func allowsMotion(windowVisible: Bool) -> Bool { windowVisible && isScreenActive }

    func applying(_ event: Event) -> RafuMotionConditions {
        var next = self
        switch event {
        case .screenLocked: next.screenLocked = true
        case .screenUnlocked: next.screenLocked = false
        case .displaysSlept: next.displaysAsleep = true
        case .displaysWoke: next.displaysAsleep = false
        case .sessionResignedActive: next.sessionInactive = true
        case .sessionBecameActive: next.sessionInactive = false
        }
        return next
    }
}

/// The one app-wide source of truth for "can anybody see the screen". A view
/// reads the combined per-window answer through `\.rafuMotionAllowed`, which
/// `rafuMotionScope()` sets on each window's root. Continuous animation in a
/// SwiftUI window re-renders every display frame (120 Hz on ProMotion) even
/// behind a lock screen, so everything that loops must stop when this says no.
@MainActor
@Observable
final class RafuMotionGate {
    static let shared = RafuMotionGate()

    private(set) var conditions = RafuMotionConditions()

    var isScreenActive: Bool { conditions.isScreenActive }

    @ObservationIgnored
    private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

    init() {}

    /// Installs the lock, display-sleep and session observers and reads the
    /// current lock state, because the app can launch behind a locked screen.
    /// Idempotent; called once at launch.
    func start() {
        guard observers.isEmpty else { return }
        var initial = RafuMotionConditions()
        initial.screenLocked = Self.isScreenLockedNow()
        initial.displaysAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
        apply(initial)

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked"), .screenLocked)
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked"), .screenUnlocked)
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification, .displaysSlept)
        observe(workspace, NSWorkspace.screensDidWakeNotification, .displaysWoke)
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification, .sessionResignedActive)
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification, .sessionBecameActive)
    }

    func stop() {
        for observer in observers {
            observer.center.removeObserver(observer.token)
        }
        observers = []
    }

    func handle(_ event: RafuMotionConditions.Event) {
        apply(conditions.applying(event))
    }

    private func apply(_ next: RafuMotionConditions) {
        // Assign only on change: `@Observable` notifies on every write.
        if conditions != next { conditions = next }
    }

    private func observe(
        _ center: NotificationCenter, _ name: Notification.Name,
        _ event: RafuMotionConditions.Event
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        observers.append((center, token))
    }

    private static func isScreenLockedNow() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

extension EnvironmentValues {
    /// `false` while this window is occluded, the screen is locked, or the
    /// displays sleep. Loops (spinners, timelines, the mascot) stop on
    /// `false` and show their still pose, as under Reduce Motion.
    @Entry var rafuMotionAllowed = true
}

extension View {
    /// Sets `\.rafuMotionAllowed` for this window's content from the window's
    /// occlusion state and `RafuMotionGate`. Apply once at each window root.
    func rafuMotionScope() -> some View {
        modifier(RafuMotionScope())
    }
}

private struct RafuMotionScope: ViewModifier {
    @State private var windowVisible = true
    private var gate = RafuMotionGate.shared

    func body(content: Content) -> some View {
        content
            .environment(
                \.rafuMotionAllowed, gate.conditions.allowsMotion(windowVisible: windowVisible)
            )
            .background(
                WindowOcclusionReader { visible in
                    if windowVisible != visible { windowVisible = visible }
                }
            )
    }
}

/// Reports its window's `occlusionState.contains(.visible)` on attach and on
/// every `NSWindow.didChangeOcclusionStateNotification`.
private struct WindowOcclusionReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> WindowOcclusionView {
        let view = WindowOcclusionView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ nsView: WindowOcclusionView, context: Context) {
        nsView.onChange = onChange
    }
}

private final class WindowOcclusionView: NSView {
    var onChange: ((Bool) -> Void)?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Selector observers are removed automatically when the view is
        // deallocated; `viewWillMove(toWindow:)` removes them on a move.
        NotificationCenter.default.addObserver(
            self, selector: #selector(occlusionDidChange(_:)),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
        // Attaching happens inside a SwiftUI update; report on the next turn
        // so the state write is not made during that update.
        DispatchQueue.main.async { [weak self] in self?.report() }
    }

    @objc private func occlusionDidChange(_ notification: Notification) {
        report()
    }

    private func report() {
        guard let window else { return }
        onChange?(window.occlusionState.contains(.visible))
    }
}
