import AppKit
import ApplicationServices
import Observation
import SwiftUI

// Native app docking.
//
// macOS has no public API that embeds another app's live window in a view,
// and screen capture needs Screen Recording permission. Docking instead moves
// and sizes the app's real window so it sits exactly over the card body, and
// keeps it there while the board pans, zooms, scrolls, or the Rafu window
// moves. The user types and clicks in the real app.
//
// Rules:
// - Docking starts only from an explicit Dock action. Restoring a board never
//   docks, launches, or moves anything.
// - Rafu needs the user's Accessibility permission. Rendering only checks it;
//   the Dock button prompts once per launch.
// - Rafu sets only the window's position and size, and asks the window to
//   raise (`AXRaise`). It never sends synthetic keyboard or pointer input.
// - Limitation: Rafu cannot keep another app's window above its own. When the
//   user clicks elsewhere in Rafu, the Rafu window covers the docked window;
//   clicking the card body brings the app forward again.
// - Limitation: window text cannot scale, so docking needs 75% board zoom.
//   Below that, and whenever the card is not visible, the app is hidden and
//   returns when the card is visible again.
// - Limitation: Accessibility calls are synchronous IPC to the other app. They
//   run on the main actor with a 0.25 s messaging timeout; an app that does not
//   answer is undocked instead of being retried every frame.

/// What one card measures for docking. Both rects describe the card body.
nonisolated struct CanvasDockFrames: Equatable, Sendable {
    /// In SwiftUI's global space: the hosting view, top-left origin.
    var global: CGRect
    /// In the board surface's named coordinate space.
    var board: CGRect
}

/// Accessibility helpers. Attribute names are the documented string values,
/// written literally so no mutable SDK global is read under strict concurrency.
nonisolated enum CanvasAX {
    static let focusedWindow = "AXFocusedWindow"
    static let mainWindow = "AXMainWindow"
    static let windows = "AXWindows"
    static let role = "AXRole"
    static let subrole = "AXSubrole"
    static let title = "AXTitle"
    static let description = "AXDescription"
    static let value = "AXValue"
    static let children = "AXChildren"
    static let position = "AXPosition"
    static let size = "AXSize"
    static let minimized = "AXMinimized"
    static let numberOfCharacters = "AXNumberOfCharacters"
    static let stringForRange = "AXStringForRange"
    static let raise = "AXRaise"
    static let windowRole = "AXWindow"
    static let standardWindow = "AXStandardWindow"
    static let moved = "AXMoved"
    static let resized = "AXResized"
    static let destroyed = "AXUIElementDestroyed"
    static let miniaturized = "AXWindowMiniaturized"
    static let promptOption = "AXTrustedCheckOptionPrompt"
    static let messagingTimeout: Float = 0.25

    /// A timeout set on one element does not cover the elements read from it.
    /// The system-wide element sets it for every Accessibility call Rafu makes.
    static func boundMessaging() {
        _ = AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), messagingTimeout)
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
        else { return nil }
        return value
    }

    static func element(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        guard let value = attribute(element, name),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        // The type ID check above makes this downcast exact.
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func elements(_ element: AXUIElement, _ name: String, limit: Int) -> [AXUIElement] {
        var values: CFArray?
        guard
            AXUIElementCopyAttributeValues(element, name as CFString, 0, limit, &values)
                == .success,
            let values
        else { return [] }
        return (values as NSArray).compactMap { item -> AXUIElement? in
            let object = item as AnyObject
            guard CFGetTypeID(object) == AXUIElementGetTypeID() else { return nil }
            return unsafeDowncast(object, to: AXUIElement.self)
        }
    }

    static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    static func bool(_ element: AXUIElement, _ name: String) -> Bool? {
        (attribute(element, name) as? NSNumber)?.boolValue
    }

    private static func axValue(_ element: AXUIElement, _ name: String) -> AXValue? {
        guard let value = attribute(element, name), CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return unsafeDowncast(value, to: AXValue.self)
    }

    /// The element's frame in Accessibility (top-left) screen coordinates.
    static func frame(_ element: AXUIElement) -> CGRect? {
        guard let positionValue = axValue(element, position),
            let sizeValue = axValue(element, size)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &origin),
            AXValueGetValue(sizeValue, .cgSize, &extent)
        else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    /// Size, position, then size again: moving to another display can clamp
    /// the first size to the old display.
    static func setFrame(_ element: AXUIElement, _ rect: CGRect) -> AXError {
        var origin = rect.origin
        var extent = rect.size
        guard let positionValue = AXValueCreate(.cgPoint, &origin),
            let sizeValue = AXValueCreate(.cgSize, &extent)
        else { return .failure }
        _ = AXUIElementSetAttributeValue(element, size as CFString, sizeValue)
        let moved = AXUIElementSetAttributeValue(element, position as CFString, positionValue)
        let sized = AXUIElementSetAttributeValue(element, size as CFString, sizeValue)
        return moved == .success ? sized : moved
    }

    static func isStandardWindow(_ element: AXUIElement) -> Bool {
        string(element, role) == windowRole
            && string(element, subrole) == standardWindow
            && bool(element, minimized) != true
    }

    /// The focused, then main, then first standard window not in `excluding`.
    static func frontWindow(app: AXUIElement, excluding: [AXUIElement]) -> AXUIElement? {
        var candidates: [AXUIElement] = []
        if let focused = element(app, focusedWindow) { candidates.append(focused) }
        if let main = element(app, mainWindow) { candidates.append(main) }
        candidates += elements(app, windows, limit: 50)
        return candidates.first { window in
            isStandardWindow(window) && !excluding.contains { CFEqual($0, window) }
        }
    }

    /// A bounded summary of the window at `frame` (or the focused window).
    /// This walks another process's tree, so it runs off the main actor.
    @concurrent static func summary(pid: pid_t, near frame: CGRect?, appName: String) async
        -> String?
    {
        guard AXIsProcessTrusted() else { return nil }
        boundMessaging()
        let app = AXUIElementCreateApplication(pid)
        let all = elements(app, windows, limit: 50)
        let matched = frame.flatMap { expected in
            all.first { window in
                self.frame(window).map {
                    CanvasDockGeometry.isRafuPlacement($0, expected: expected)
                } ?? false
            }
        }
        guard let window = matched ?? element(app, focusedWindow) ?? all.first else {
            return nil
        }
        let deadline = ContinuousClock.now + .seconds(2)
        return CanvasAXSummary.summarize(
            root: CanvasAXElementNode(element: window),
            header: "Accessibility summary of the docked \(appName) window (read-only)",
            visibleRect: self.frame(window),
            shouldContinue: { ContinuousClock.now < deadline && !Task.isCancelled })
    }
}

/// A live Accessibility element read through `CanvasAXSummary`.
nonisolated struct CanvasAXElementNode: CanvasAXSummaryNode {
    let element: AXUIElement

    var role: String? { CanvasAX.string(element, CanvasAX.role) }
    var subrole: String? { CanvasAX.string(element, CanvasAX.subrole) }
    var title: String? {
        CanvasAX.string(element, CanvasAX.title) ?? CanvasAX.string(element, CanvasAX.description)
    }
    var frame: CGRect? { CanvasAX.frame(element) }

    /// Long text is read as a bounded prefix so a large document never
    /// crosses the process boundary whole.
    var value: String? {
        let limit = CanvasAXSummary.maximumFieldCharacters + 1
        if let count = CanvasAX.attribute(element, CanvasAX.numberOfCharacters) as? NSNumber,
            count.intValue > limit
        {
            var range = CFRange(location: 0, length: limit)
            guard let parameter = AXValueCreate(.cfRange, &range) else { return nil }
            var result: CFTypeRef?
            guard
                AXUIElementCopyParameterizedAttributeValue(
                    element, CanvasAX.stringForRange as CFString, parameter, &result) == .success
            else { return nil }
            return result as? String
        }
        let raw = CanvasAX.attribute(element, CanvasAX.value)
        if let text = raw as? String { return text }
        if let number = raw as? NSNumber { return number.stringValue }
        return nil
    }

    func children(limit: Int) -> [CanvasAXElementNode] {
        CanvasAX.elements(element, CanvasAX.children, limit: limit).map {
            CanvasAXElementNode(element: $0)
        }
    }
}

/// The C callback for window notifications. It receives only a numeric token,
/// never an object pointer, and hops to the main actor before reading state.
nonisolated private func canvasDockObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    let name = notification as String
    let token = Int(bitPattern: refcon)
    guard token != 0 else { return }
    if Thread.isMainThread {
        MainActor.assumeIsolated { CanvasAppDocking.shared.received(name, token: token) }
    } else {
        Task { @MainActor in CanvasAppDocking.shared.received(name, token: token) }
    }
}

/// A zero-size view in the card body. It locates the hosting window and view;
/// it never takes clicks or focus.
struct CanvasDockAnchor: NSViewRepresentable {
    let cardID: CanvasCardID
    let owner: UUID

    func makeNSView(context: Context) -> AnchorView {
        AnchorView(cardID: cardID, owner: owner)
    }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        let cardID: CanvasCardID
        let owner: UUID
        init(cardID: CanvasCardID, owner: UUID) {
            self.cardID = cardID
            self.owner = owner
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var acceptsFirstResponder: Bool { false }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            CanvasAppDocking.shared.anchorMoved(self)
        }
    }
}

@MainActor
@Observable
final class CanvasAppDocking {
    static let shared = CanvasAppDocking()
    static let maximumDocks = 4
    static let accessibilitySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")

    private(set) var states: [CanvasCardID: CanvasDockState] = [:]
    /// The last checked permission. Checking never prompts.
    private(set) var isTrusted = false

    @ObservationIgnored private var docks: [CanvasCardID: Dock] = [:]
    @ObservationIgnored private var mounts: [CanvasCardID: Mount] = [:]
    @ObservationIgnored private var tokens: [Int: CanvasCardID] = [:]
    @ObservationIgnored private var nextToken = 1
    @ObservationIgnored private var hasPrompted = false
    @ObservationIgnored private var appObservers: [any NSObjectProtocol] = []

    private init() {}

    func state(for cardID: CanvasCardID) -> CanvasDockState { states[cardID] ?? .notDocked }

    // MARK: Permission

    /// Checks Accessibility permission without prompting.
    @discardableResult func refreshTrust() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted { isTrusted = trusted }
        if trusted {
            for (id, state) in states where state == .needsPermission { states[id] = nil }
        }
        return trusted
    }

    /// Prompts at most once per launch, and only for an explicit user action.
    private func ensureTrust(prompt: Bool) -> Bool {
        if refreshTrust() { return true }
        if prompt, !hasPrompted {
            hasPrompted = true
            let options = [CanvasAX.promptOption: true] as CFDictionary
            let trusted = AXIsProcessTrustedWithOptions(options)
            if trusted != isTrusted { isTrusted = trusted }
        }
        return isTrusted
    }

    func openAccessibilitySettings() {
        guard let url = Self.accessibilitySettingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Agent contract

    /// Opens the app and docks it into an existing native app card. This never
    /// prompts for permission: without it the app opens undocked and this
    /// returns false.
    func open(bundleID: String, in cardID: CanvasCardID, session: WorkspaceSession) async
        -> Bool
    {
        guard let card = self.card(cardID, in: session),
            case .nativeApp(let cardBundleID) = card.content, cardBundleID == bundleID
        else { return false }
        guard refreshTrust() else {
            states[cardID] = .needsPermission
            Self.launch(bundleID: bundleID)
            return false
        }
        return await dock(
            card: cardID, bundleID: bundleID, appName: card.title, session: session,
            prompt: false)
    }

    /// A bounded plain-text Accessibility summary of the docked window, or nil
    /// when the card is not docked or permission is missing.
    func inspect(cardID: CanvasCardID) async -> String? {
        guard let dock = docks[cardID], AXIsProcessTrusted() else { return nil }
        return await CanvasAX.summary(
            pid: dock.app.processIdentifier, near: dock.expectedFrame ?? dock.previousFrame,
            appName: dock.appName)
    }

    // MARK: Explicit actions

    /// Launches or activates the app and docks its front standard window.
    @discardableResult func dock(
        card cardID: CanvasCardID, bundleID: String, appName: String,
        session: WorkspaceSession, prompt: Bool
    ) async -> Bool {
        if let dock = docks[cardID] {
            schedule(dock)
            return true
        }
        guard states[cardID] != .docking, let boardID = self.boardID(of: cardID, in: session)
        else {
            return false
        }
        guard ensureTrust(prompt: prompt) else {
            states[cardID] = .needsPermission
            return false
        }
        if let problem = admissionProblem(bundleID: bundleID, appName: appName) {
            states[cardID] = .failed(problem)
            return false
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            states[cardID] = .failed("\(appName) is not installed.")
            return false
        }
        states[cardID] = .docking
        let launched = await Self.launch(url: url)
        guard states[cardID] == .docking else { return false }
        guard launched,
            let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .first(where: { !$0.isTerminated })
        else {
            states[cardID] = .failed("\(appName) could not be opened.")
            return false
        }
        guard let window = await findWindow(app: app, card: cardID) else {
            if states[cardID] == .docking {
                states[cardID] = .failed(
                    "\(appName) has no window to dock. Open a window in \(appName), then try again."
                )
            }
            return false
        }
        // Another request may have docked while this one waited.
        if let problem = admissionProblem(bundleID: bundleID, appName: appName) {
            states[cardID] = .failed(problem)
            return false
        }
        let token = nextToken
        nextToken += 1
        let dock = Dock(
            cardID: cardID, boardID: boardID, bundleID: bundleID, appName: appName, app: app,
            window: window, token: token, session: session)
        dock.previousFrame = CanvasAX.frame(window)
        dock.expectedFrame = dock.previousFrame
        guard observe(dock) else {
            states[cardID] = .failed("Rafu cannot follow the \(appName) window.")
            return false
        }
        docks[cardID] = dock
        tokens[token] = cardID
        states[cardID] = .docked
        installAppObservers()
        apply(dock)
        if states[cardID] == .docked { raise(dock) }
        return true
    }

    /// Puts the window back where it was before docking.
    func undock(_ cardID: CanvasCardID) {
        if let dock = docks[cardID] {
            release(dock, state: .notDocked, restoreFrame: true)
        } else {
            setState(.notDocked, for: cardID)
        }
    }

    /// The user clicked the card body: keep the window in place and bring the
    /// app forward. This is an activation request, not synthetic input.
    func bringForward(_ cardID: CanvasCardID) {
        guard let dock = docks[cardID] else { return }
        apply(dock)
        guard states[cardID] == .docked else { return }
        raise(dock)
    }

    /// Re-evaluates the card's placement after its board or card changed.
    func refresh(_ cardID: CanvasCardID) {
        guard let dock = docks[cardID] else { return }
        schedule(dock)
    }

    static func launch(bundleID: String) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
    }

    // MARK: Card geometry

    func mount(_ cardID: CanvasCardID, owner: UUID) {
        _ = entry(cardID, owner: owner)
        refreshTrust()
        refresh(cardID)
    }

    func unmount(_ cardID: CanvasCardID, owner: UUID) {
        guard mounts[cardID]?.owner == owner else { return }
        mounts[cardID] = nil
        refresh(cardID)
    }

    func updateGeometry(_ cardID: CanvasCardID, owner: UUID, frames: CanvasDockFrames) {
        let mount = entry(cardID, owner: owner)
        guard mount.frames != frames else { return }
        mount.frames = frames
        refresh(cardID)
    }

    fileprivate func anchorMoved(_ anchor: CanvasDockAnchor.AnchorView) {
        if anchor.window == nil {
            guard let mount = mounts[anchor.cardID], mount.owner == anchor.owner else { return }
            mount.anchor = nil
        } else {
            entry(anchor.cardID, owner: anchor.owner).anchor = anchor
        }
        refresh(anchor.cardID)
    }

    /// The newest presentation of a card owns its geometry. Lifecycle,
    /// geometry, and window callbacks can arrive in any order.
    private func entry(_ cardID: CanvasCardID, owner: UUID) -> Mount {
        if let mount = mounts[cardID], mount.owner == owner { return mount }
        let mount = Mount(owner: owner)
        mounts[cardID] = mount
        return mount
    }

    // MARK: Placement

    private func admissionProblem(bundleID: String, appName: String) -> String? {
        if bundleID == Bundle.main.bundleIdentifier { return "Rafu cannot dock its own windows." }
        if docks.values.contains(where: { $0.bundleID == bundleID }) {
            return "\(appName) is already docked in another card."
        }
        if docks.count >= Self.maximumDocks {
            return "Up to \(Self.maximumDocks) apps can be docked. Undock one first."
        }
        return nil
    }

    private static func launch(url: URL) async -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) {
                _, error in
                continuation.resume(returning: error == nil)
            }
        }
    }

    /// A launching app may need a moment to open its first window. This is a
    /// bounded wait (3 s) that ends early when the user cancels.
    private func findWindow(app: NSRunningApplication, card: CanvasCardID) async -> AXUIElement? {
        CanvasAX.boundMessaging()
        let element = AXUIElementCreateApplication(app.processIdentifier)
        for attempt in 0..<20 {
            if attempt > 0 { try? await Task.sleep(for: .milliseconds(150)) }
            guard states[card] == .docking, !app.isTerminated, !Task.isCancelled else {
                return nil
            }
            let taken = docks.values.map(\.window)
            if let window = CanvasAX.frontWindow(app: element, excluding: taken) {
                return window
            }
        }
        return nil
    }

    private func observe(_ dock: Dock) -> Bool {
        var created: AXObserver?
        guard
            AXObserverCreate(dock.app.processIdentifier, canvasDockObserverCallback, &created)
                == .success,
            let observer = created
        else { return false }
        let refcon = UnsafeMutableRawPointer(bitPattern: dock.token)
        for name in [CanvasAX.moved, CanvasAX.resized, CanvasAX.destroyed, CanvasAX.miniaturized] {
            _ = AXObserverAddNotification(observer, dock.window, name as CFString, refcon)
        }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        dock.observer = observer
        return true
    }

    /// At most one placement per display frame.
    private func schedule(_ dock: Dock) {
        guard dock.pendingApply == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let wait = dock.throttle.delay(at: now)
        guard wait > 0 else {
            apply(dock)
            return
        }
        dock.pendingApply = Task { [weak self, weak dock] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, let dock, !Task.isCancelled else { return }
            dock.pendingApply = nil
            apply(dock)
        }
    }

    private func apply(_ dock: Dock) {
        dock.throttle.recordApply(at: ProcessInfo.processInfo.systemUptime)
        guard docks[dock.cardID] === dock else { return }
        guard let session = dock.session, let board = session.canvas.boards[dock.boardID],
            let index = board.cards.firstIndex(where: { $0.id == dock.cardID })
        else {
            // The card or its board is gone: give the window back.
            release(dock, state: .notDocked, restoreFrame: true)
            return
        }
        guard !dock.app.isTerminated else {
            release(dock, state: .undocked("\(dock.appName) quit."), restoreFrame: false)
            return
        }
        let mount = mounts[dock.cardID]
        let anchor = mount?.anchor
        let hostWindow = anchor?.window
        if let hostWindow { watch(hostWindow, for: dock) }
        var conditions = CanvasDockConditions()
        conditions.isLive = session.canvasResources[dock.boardID]?.permitsLiveContent == true
        conditions.isMounted = mount?.frames != nil && hostWindow != nil
        conditions.scale = board.viewport.scale
        if let frames = mount?.frames {
            conditions.body = frames.global
            conditions.visibleBoard = CanvasDockGeometry.visibleBoard(
                global: frames.global, inBoard: frames.board, boardSize: board.visibleSize)
        }
        conditions.isCovered = CanvasDockVisibility.isCovered(
            index: index,
            in: board.cards.map {
                CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.width, height: $0.rect.height)
            })
        conditions.isHostWindowVisible =
            hostWindow.map {
                $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
            } ?? true
        conditions.isFrontmostRafuOrDocked = isFrontmostRafuOrDocked()
        switch CanvasDockVisibility.placement(conditions) {
        case .place(let rect):
            guard let anchor, let target = axRect(global: rect, anchor: anchor) else {
                pause(dock, .windowHidden)
                return
            }
            place(dock, at: target)
        case .pause(let reason):
            pause(dock, reason)
        }
    }

    private func place(_ dock: Dock, at target: CGRect) {
        if dock.isHiddenByRafu {
            _ = dock.app.unhide()
            dock.isHiddenByRafu = false
        }
        let current = CanvasAX.frame(dock.window)
        if current.map({ $0.integral != target.integral }) ?? true {
            switch CanvasAX.setFrame(dock.window, target) {
            case .success:
                break
            case .invalidUIElement:
                release(
                    dock, state: .undocked("The \(dock.appName) window closed."),
                    restoreFrame: false)
                return
            case .cannotComplete:
                release(
                    dock, state: .undocked("\(dock.appName) is not responding."),
                    restoreFrame: false)
                return
            default:
                // An app may refuse a size. Check its actual bounds below.
                break
            }
        }
        dock.expectedFrame = CanvasAX.frame(dock.window) ?? target
        if let frame = dock.expectedFrame, !CanvasDockGeometry.fits(frame, inside: target) {
            pause(dock, .windowDoesNotFit)
            return
        }
        setState(.docked, for: dock.cardID)
    }

    /// Short pauses hide the app; a hidden Ensemble gives the window back its
    /// previous frame so it stays usable. Both return when the card is visible.
    private func pause(_ dock: Dock, _ reason: CanvasDockPauseReason) {
        let previous = states[dock.cardID]
        setState(.paused(reason), for: dock.cardID)
        if reason == .ensembleHidden {
            if dock.isHiddenByRafu {
                _ = dock.app.unhide()
                dock.isHiddenByRafu = false
            }
            guard previous != .paused(.ensembleHidden), let frame = dock.previousFrame else {
                return
            }
            _ = CanvasAX.setFrame(dock.window, frame)
            dock.expectedFrame = CanvasAX.frame(dock.window) ?? frame
            return
        }
        guard !dock.isHiddenByRafu, !dock.app.isHidden else { return }
        if dock.app.hide() {
            dock.isHiddenByRafu = true
        } else if let frame = dock.previousFrame {
            _ = CanvasAX.setFrame(dock.window, frame)
            dock.expectedFrame = CanvasAX.frame(dock.window) ?? frame
        }
    }

    private func raise(_ dock: Dock) {
        _ = AXUIElementPerformAction(dock.window, CanvasAX.raise as CFString)
        NSApp.yieldActivation(to: dock.app)
        _ = dock.app.activate(from: .current, options: [])
    }

    private func release(_ dock: Dock, state: CanvasDockState, restoreFrame: Bool) {
        dock.pendingApply?.cancel()
        dock.pendingApply = nil
        if let observer = dock.observer {
            for name in [
                CanvasAX.moved, CanvasAX.resized, CanvasAX.destroyed, CanvasAX.miniaturized,
            ] {
                _ = AXObserverRemoveNotification(observer, dock.window, name as CFString)
            }
            CFRunLoopRemoveSource(
                CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            dock.observer = nil
        }
        for token in dock.hostObservers { NotificationCenter.default.removeObserver(token) }
        dock.hostObservers = []
        dock.hostWindow = nil
        if dock.isHiddenByRafu, !dock.app.isTerminated {
            _ = dock.app.unhide()
            dock.isHiddenByRafu = false
        }
        if restoreFrame, !dock.app.isTerminated, let frame = dock.previousFrame {
            _ = CanvasAX.setFrame(dock.window, frame)
        }
        if docks[dock.cardID] === dock { docks[dock.cardID] = nil }
        tokens[dock.token] = nil
        setState(state, for: dock.cardID)
    }

    /// `.notDocked` is the default, so it is stored as no entry.
    private func setState(_ state: CanvasDockState, for cardID: CanvasCardID) {
        let stored: CanvasDockState? = state == .notDocked ? nil : state
        if states[cardID] != stored { states[cardID] = stored }
    }

    // MARK: Notifications

    /// A window notification from the docked app, already on the main actor.
    func received(_ name: String, token: Int) {
        guard let cardID = tokens[token], let dock = docks[cardID] else { return }
        switch name {
        case CanvasAX.destroyed:
            release(
                dock, state: .undocked("The \(dock.appName) window closed."), restoreFrame: false)
        case CanvasAX.miniaturized:
            release(
                dock, state: .undocked("The \(dock.appName) window was minimised."),
                restoreFrame: false)
        case CanvasAX.moved, CanvasAX.resized:
            guard !dock.isHiddenByRafu, let expected = dock.expectedFrame,
                let current = CanvasAX.frame(dock.window),
                !CanvasDockGeometry.isRafuPlacement(current, expected: expected)
            else { return }
            // The user moved or resized the window: leave it where they put it.
            release(
                dock, state: .undocked("\(dock.appName) was moved out of the card."),
                restoreFrame: false)
        default:
            break
        }
    }

    private func watch(_ window: NSWindow, for dock: Dock) {
        guard dock.hostWindow !== window else { return }
        for token in dock.hostObservers { NotificationCenter.default.removeObserver(token) }
        dock.hostWindow = window
        let cardID = dock.cardID
        let names: [Notification.Name] = [
            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
            NSWindow.didChangeScreenNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didChangeOcclusionStateNotification,
        ]
        dock.hostObservers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                _ in
                MainActor.assumeIsolated { CanvasAppDocking.shared.refresh(cardID) }
            }
        }
        // A closing workspace window gives the app window back at once.
        dock.hostObservers.append(
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { _ in
                MainActor.assumeIsolated { CanvasAppDocking.shared.hostWindowClosing(cardID) }
            })
    }

    private func hostWindowClosing(_ cardID: CanvasCardID) {
        guard let dock = docks[cardID] else { return }
        release(dock, state: .notDocked, restoreFrame: true)
    }

    private func installAppObservers() {
        guard appObservers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let local = NotificationCenter.default
        let refreshAll: @Sendable (Notification) -> Void = { _ in
            MainActor.assumeIsolated { CanvasAppDocking.shared.refreshAll() }
        }
        appObservers = [
            workspace.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                queue: .main, using: refreshAll),
            workspace.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                queue: .main, using: refreshAll),
            local.addObserver(
                forName: NSApplication.didHideNotification, object: nil, queue: .main,
                using: refreshAll),
            local.addObserver(
                forName: NSApplication.didUnhideNotification, object: nil, queue: .main,
                using: refreshAll),
            local.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated {
                    CanvasAppDocking.shared.refreshTrust()
                    CanvasAppDocking.shared.refreshAll()
                }
            },
            local.addObserver(
                forName: NSApplication.willTerminateNotification, object: nil, queue: .main
            ) { _ in
                MainActor.assumeIsolated { CanvasAppDocking.shared.releaseAll() }
            },
        ]
    }

    private func refreshAll() {
        for dock in docks.values { schedule(dock) }
    }

    /// Rafu is quitting: every window goes back to where it was.
    private func releaseAll() {
        for dock in Array(docks.values) {
            release(dock, state: .notDocked, restoreFrame: true)
        }
    }

    // MARK: Geometry helpers

    private func isFrontmostRafuOrDocked() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return true }
        if front.processIdentifier == ProcessInfo.processInfo.processIdentifier { return true }
        return docks.values.contains { $0.app.processIdentifier == front.processIdentifier }
    }

    /// SwiftUI global (hosting view, top-left) → window → screen → AX.
    private func axRect(global rect: CGRect, anchor: NSView) -> CGRect? {
        guard let window = anchor.window,
            let root = Self.hostingRoot(of: anchor) ?? window.contentView,
            let primary = NSScreen.screens.first
        else { return nil }
        let local =
            root.isFlipped
            ? rect : CanvasDockGeometry.flipped(rect, inHeight: Double(root.bounds.height))
        let inWindow = root.convert(local, to: nil)
        let onScreen = window.convertToScreen(inWindow)
        return CanvasDockGeometry.axRect(
            screen: onScreen, primaryScreenHeight: Double(primary.frame.maxY))
    }

    /// SwiftUI's global space belongs to the nearest enclosing hosting view.
    private static func hostingRoot(of view: NSView) -> NSView? {
        var candidate = view.superview
        while let current = candidate {
            if String(describing: type(of: current)).contains("NSHostingView") { return current }
            candidate = current.superview
        }
        return nil
    }

    private func card(_ cardID: CanvasCardID, in session: WorkspaceSession) -> CanvasCard? {
        for board in session.canvas.boards.values {
            if let card = board.cards.first(where: { $0.id == cardID }) { return card }
        }
        return nil
    }

    private func boardID(of cardID: CanvasCardID, in session: WorkspaceSession) -> CanvasID? {
        session.canvas.boards.values.first { board in
            board.cards.contains { $0.id == cardID }
        }?.id
    }
}

/// One docked window. Only main-actor code touches it.
@MainActor
private final class Dock {
    let cardID: CanvasCardID
    let boardID: CanvasID
    let bundleID: String
    let appName: String
    let app: NSRunningApplication
    let window: AXUIElement
    let token: Int
    weak var session: WorkspaceSession?
    var observer: AXObserver?
    /// The window's frame before docking, in AX coordinates.
    var previousFrame: CGRect?
    /// The frame Rafu last placed, read back from the app.
    var expectedFrame: CGRect?
    var isHiddenByRafu = false
    var throttle = CanvasDockThrottle(framesPerSecond: NSScreen.main?.maximumFramesPerSecond ?? 60)
    var pendingApply: Task<Void, Never>?
    var hostObservers: [any NSObjectProtocol] = []
    weak var hostWindow: NSWindow?

    init(
        cardID: CanvasCardID, boardID: CanvasID, bundleID: String, appName: String,
        app: NSRunningApplication, window: AXUIElement, token: Int, session: WorkspaceSession
    ) {
        self.cardID = cardID
        self.boardID = boardID
        self.bundleID = bundleID
        self.appName = appName
        self.app = app
        self.window = window
        self.token = token
        self.session = session
    }
}

/// Where one presentation of a card is on screen.
@MainActor
private final class Mount {
    let owner: UUID
    weak var anchor: NSView?
    var frames: CanvasDockFrames?
    init(owner: UUID) { self.owner = owner }
}
