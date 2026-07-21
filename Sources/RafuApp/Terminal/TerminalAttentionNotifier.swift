import Foundation
import UserNotifications

/// A ready-to-post attention notification (terminal-manager.md T-E) — value
/// type only, no `UserNotifications` import, so `WorkspaceSession` and its
/// tests stay headless.
nonisolated struct TerminalAttentionNotification: Equatable, Sendable {
    let sessionID: UUID
    let title: String
    let body: String
}

/// The seam between `WorkspaceSession` and the system notification center.
/// Tests inject a spy conforming to this protocol
/// (`WorkspaceSession.attentionNotifier`) so `SystemTerminalAttentionNotifier`
/// — the concrete, `UserNotifications`-backed implementation below — is
/// NEVER constructed by a headless test. This is not stylistic: a raw
/// SwiftPM binary or the `swift test` bundle has no bundle identity, and
/// `UNUserNotificationCenter.current()` against one is known to fail or trap.
@MainActor
protocol TerminalAttentionNotifying: AnyObject {
    /// Requests notification authorization the FIRST time a bell would
    /// actually notify (never at launch) — a no-op returning `true`/`false`
    /// immediately once the OS has already recorded a decision, so this
    /// never re-prompts on a later call.
    func requestAuthorizationIfNeeded() async -> Bool
    func post(_ notification: TerminalAttentionNotification)
}

/// `UNUserNotificationCenter`-backed `TerminalAttentionNotifying`. This is
/// the ONLY file in the app importing `UserNotifications` — grep-verify
/// with `grep -rn "import UserNotifications" Sources/`. Constructed lazily,
/// only by `WorkspaceSession.resolvedAttentionNotifier()`, only when a bell
/// would actually notify (preference on, attention raised).
@MainActor
final class SystemTerminalAttentionNotifier: TerminalAttentionNotifying {
    // `nonisolated`: plain `String` constants, read from
    // `ReplyRoutingDelegate`'s `nonisolated` delegate callback below — this
    // class itself is `@MainActor`, but these two identifiers carry no
    // isolated state.
    nonisolated static let categoryIdentifier = "rafu.terminal.attention"
    nonisolated static let replyActionIdentifier = "rafu.terminal.reply"

    /// Registers the reply-capable notification category and installs the
    /// delegate that routes replies back into a live terminal. Call
    /// eagerly at launch (`RafuAppDelegate.applicationDidFinishLaunching`) —
    /// registering a category never prompts for permission, so this is safe
    /// to call unconditionally, before the user has ever enabled bell
    /// notifications or a bell has ever fired.
    static func registerCategoryAndDelegate() {
        let replyAction = UNTextInputNotificationAction(
            identifier: replyActionIdentifier,
            title: "Reply",
            // Empty options (NOT `.foreground`): replying must never steal
            // focus from whatever the user is doing (terminal-manager.md
            // T-E).
            options: [],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Message…"
        )
        let category = UNNotificationCategory(
            identifier: categoryIdentifier,
            actions: [replyAction],
            intentIdentifiers: [],
            options: []
        )
        let center = UNUserNotificationCenter.current()
        center.setNotificationCategories([category])
        center.delegate = replyRoutingDelegate
    }

    /// Held statically (not per-notifier-instance) since the delegate must
    /// survive for the app's lifetime and there is exactly one
    /// `UNUserNotificationCenter`.
    private static let replyRoutingDelegate = ReplyRoutingDelegate()

    func requestAuthorizationIfNeeded() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    func post(_ notification: TerminalAttentionNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.categoryIdentifier = Self.categoryIdentifier
        // Macos Notification Center persists bodies and may surface them on
        // the lock screen regardless of this setting — `.active` only
        // avoids the more disruptive time-sensitive/critical presentation,
        // it does not change persistence. Documented residual exposure,
        // not a bug: terminal output snippets are already bounded/sanitized
        // before reaching here (`TerminalAttentionPolicy.snippet`).
        content.interruptionLevel = .active
        // ONLY the session id — never the snippet, never a path — travels
        // in `userInfo`; the reply-delivery path resolves the live session
        // from this UUID (`TerminalAttentionCenter.deliverReply`).
        content.userInfo = ["sessionID": notification.sessionID.uuidString]
        let request = UNNotificationRequest(
            identifier: notification.sessionID.uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Routes a notification reply into a live terminal via
/// `TerminalAttentionCenter`. `nonisolated` — `UNUserNotificationCenter`
/// invokes delegate methods off the main thread with no actor annotation of
/// its own, so (mirroring `WorkspaceTerminalController.swift`'s
/// `DelegateProxy`) this hops to the main actor explicitly rather than
/// claiming an isolation the framework does not guarantee.
private final class ReplyRoutingDelegate: NSObject, UNUserNotificationCenterDelegate {
    /// Without this, macOS SUPPRESSES banners for notifications posted by
    /// the frontmost app — and "I'm working in Rafu while an agent bells in
    /// a hidden terminal" is this feature's primary scenario, so the
    /// notification must present even when Rafu is active. This was the
    /// "bell never rang" bug: the post succeeded and the banner was
    /// silently swallowed.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler:
            @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard response.actionIdentifier == SystemTerminalAttentionNotifier.replyActionIdentifier,
            let textResponse = response as? UNTextInputNotificationResponse,
            let sessionIDString = response.notification.request.content.userInfo["sessionID"]
                as? String,
            let sessionID = UUID(uuidString: sessionIDString),
            // A reply is one line, not a script — never logged (this value
            // never touches print/os_log/Logger anywhere in this file).
            let sanitized = TerminalAttentionPolicy.sanitizedReply(textResponse.userText)
        else { return }
        Task { @MainActor in
            TerminalAttentionCenter.shared.deliverReply(sanitized, to: sessionID)
        }
    }
}
