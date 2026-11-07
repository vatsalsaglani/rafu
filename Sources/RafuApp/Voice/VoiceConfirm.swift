import AppKit
import RafuCore
import SwiftUI

/// The user's answer to a voice Confirm card.
enum VoiceConfirmAnswer: Equatable {
    /// "Allow Once", the card's default button, or `voice_confirm`.
    case allowOnce
    /// "Allow for This Session", or `voice_confirm` with `always`. Kept in
    /// memory until the session closes; never offered for a removal.
    case allowForSession
    /// Cancel, Escape, `voice_cancel`, or the session closed.
    case cancel
    /// Nobody answered within `VoiceConfirmGate.timeout`.
    case timedOut
    /// Another card was already waiting.
    case busy
}

/// What one Confirm card shows. Built from the parsed call, so it carries
/// the bounded approval summary and never a note body or a message text
/// beyond 240 characters.
struct VoiceConfirmRequest: Equatable {
    let tool: CanvasAgentTool
    let boardID: CanvasID
    let ensemble: String
    let title: String
    let summary: [String]

    /// Removals are destructive (ADR 0033): Return never runs them, and
    /// they never get a session grant.
    var isDestructive: Bool { tool == .nodeRemove || tool == .edgeRemove }
    var offersSessionGrant: Bool { !isDestructive }
    var actionTitle: String { isDestructive ? "Remove" : "Allow Once" }

    var message: String {
        let lines = ["Rafu (voice) wants to do this on \(ensemble)."] + summary
        return lines.joined(separator: "\n")
    }

    init(call: CanvasAgentToolCall, board: CanvasBoardState) {
        tool = call.tool
        boardID = board.id
        ensemble = CanvasAgentText.singleLine(board.title, limit: 80)
        title = "\(call.tool.actionTitle)?"
        summary = Array(call.approvalSummary.prefix(8))
    }

    /// A grant key: one tool on one Ensemble.
    var grantKey: String { "\(tool.rawValue)|\(boardID.rawValue.uuidString)" }
}

/// Shows a card and reports one answer. Returns a closure that removes the
/// card, or nil when no window could hold it (the spoken answer and the
/// timeout still work then).
typealias VoiceConfirmPresenter =
    @MainActor (
        _ request: VoiceConfirmRequest, _ answer: @escaping @MainActor (VoiceConfirmAnswer) -> Void
    )
    -> (@MainActor () -> Void)?

/// At most one waiting Confirm card per voice session. A click, Escape, a
/// spoken `voice_confirm` / `voice_cancel`, the timeout, or the session
/// closing resolves the same continuation, once.
@MainActor
final class VoiceConfirmGate {
    static let timeout: Duration = .seconds(60)

    private var waiter: CheckedContinuation<VoiceConfirmAnswer, Never>?
    private var pending: VoiceConfirmRequest?
    private var dismiss: (@MainActor () -> Void)?
    private var timer: Task<Void, Never>?

    var isPending: Bool { waiter != nil }

    func ask(
        _ request: VoiceConfirmRequest, timeout: Duration = VoiceConfirmGate.timeout,
        present: VoiceConfirmPresenter
    ) async -> VoiceConfirmAnswer {
        guard waiter == nil else { return .busy }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            pending = request
            let dismissal = present(request) { [weak self] answer in self?.resolve(answer) }
            // A presenter that answered at once already resumed the waiter.
            guard waiter != nil else {
                dismissal?()
                return
            }
            dismiss = dismissal
            timer = Task { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    return
                }
                self?.resolve(.timedOut)
            }
        }
    }

    /// Resolves the waiting card. Returns false when nothing waits. A
    /// session grant asked for a removal counts as once.
    @discardableResult
    func resolve(_ answer: VoiceConfirmAnswer) -> Bool {
        guard let waiter else { return false }
        var answer = answer
        if answer == .allowForSession, pending?.offersSessionGrant != true { answer = .allowOnce }
        self.waiter = nil
        pending = nil
        timer?.cancel()
        timer = nil
        let dismiss = dismiss
        self.dismiss = nil
        dismiss?()
        waiter.resume(returning: answer)
        return true
    }
}

/// The live presenter: a Rafu popup sheet on the workspace window
/// (`RafuPopupPresenter`, ADR 0033).
@MainActor
enum VoiceConfirmCard {
    static func present(
        _ request: VoiceConfirmRequest, answer: @escaping @MainActor (VoiceConfirmAnswer) -> Void
    ) -> (@MainActor () -> Void)? {
        guard RafuPopupPresenter.parentWindow() != nil else { return nil }
        let handle = VoiceSheetHandle()
        RafuPopupPresenter.presentSheet(size: NSSize(width: 420, height: 240)) { dismiss in
            handle.dismiss = dismiss
            return RafuConfirmPopup(
                symbol: request.isDestructive ? "trash" : "waveform",
                title: request.title, message: request.message,
                actions: actions(for: request, answer: answer),
                defaultActionID: request.isDestructive ? nil : request.actionTitle
            ) {
                answer(.cancel)
            }
        }
        return { handle.close() }
    }

    static func actions(
        for request: VoiceConfirmRequest,
        answer: @escaping @MainActor (VoiceConfirmAnswer) -> Void
    ) -> [RafuConfirmPopup.Action] {
        var actions: [RafuConfirmPopup.Action] = []
        if request.offersSessionGrant {
            actions.append(.init("Allow for This Session") { answer(.allowForSession) })
        }
        actions.append(
            .init(request.actionTitle, isDestructive: request.isDestructive) {
                answer(.allowOnce)
            })
        return actions
    }
}

/// Holds the sheet's dismiss closure, so a spoken answer or the timeout can
/// close the card the user did not click.
@MainActor
private final class VoiceSheetHandle {
    var dismiss: (() -> Void)?

    func close() {
        let dismiss = dismiss
        self.dismiss = nil
        dismiss?()
    }
}
