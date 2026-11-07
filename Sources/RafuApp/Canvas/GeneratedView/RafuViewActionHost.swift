import AppKit
import Foundation
import JSONRenderCore
import RafuCore
import SwiftUI

/// The app side of one generated view: confirmations, links, and the three
/// Rafu actions (`open_file`, `focus_node`, `open_url`). Every effect is a
/// user press; nothing here starts a process, types into a terminal, writes a
/// file, or reaches the network. Activity log lines carry names and counts,
/// never paths, URLs or values.
@MainActor
final class RafuViewActionHost: ActionHost, ActionObserver {
    let cardID: CanvasCardID
    private weak var board: CanvasBoardState?
    private weak var session: WorkspaceSession?
    private weak var model: GeneratedViewCardModel?

    init(cardID: CanvasCardID, board: CanvasBoardState?, session: WorkspaceSession?) {
        self.cardID = cardID
        self.board = board
        self.session = session
    }

    func adopt(_ session: WorkspaceSession) {
        if self.session == nil { self.session = session }
    }

    /// The card model that shows this host's popups and journal.
    func attach(model: GeneratedViewCardModel) {
        self.model = model
    }

    /// The schemes a view may ask the system to open. Everything else
    /// (`javascript:`, `file:`, `data:`, custom app schemes) is refused.
    nonisolated static let allowedURLSchemes: Set<String> = ["https", "http", "mailto"]

    nonisolated static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedURLSchemes.contains(scheme) else {
            return false
        }
        if scheme == "mailto" { return true }
        return url.host()?.isEmpty == false
    }

    // MARK: ActionHost

    nonisolated func confirm(_ confirm: ActionConfirm, action: String) async -> Bool {
        await askOnMain(
            title: confirm.title, message: confirm.message,
            confirmTitle: confirm.confirmLabel ?? "Continue",
            destructive: confirm.variant == .danger)
    }

    nonisolated func navigate(_ path: String) async {
        await note("navigate ignored")
    }

    nonisolated func openURL(_ url: URL) async -> Bool {
        await openURLOnMain(url)
    }

    // MARK: ActionObserver

    nonisolated func dispatched(_ info: ActionDispatchInfo) {}

    nonisolated func settled(_ info: ActionSettleInfo) {
        let millis =
            Int(info.duration.components.seconds * 1_000)
            + Int(info.duration.components.attoseconds / 1_000_000_000_000_000)
        let line = "action \(info.name.prefix(40)) \(info.outcome.rawValue) \(millis) ms"
        Task { @MainActor [weak self] in self?.model?.appendJournal(line) }
    }

    // MARK: Rafu actions

    /// Opens a workspace file. Absolute paths, `..`, and paths outside the
    /// workspace are refused before anything touches the disk.
    func openFile(_ path: String, line: Int?) -> Bool {
        guard let session, let board,
            let relative = CanvasAgentPaths.normalizedRelative(path, allowRoot: false)
        else {
            note("open_file refused")
            return false
        }
        session.openCanvasFile(relative)
        record(board, action: "Opened a file from a view")
        return true
    }

    /// Focuses a card by id or exact title.
    func focusNode(_ reference: String) -> Bool {
        guard let board else { return false }
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let target =
            board.cards.first {
                $0.id.rawValue.uuidString.caseInsensitiveCompare(trimmed) == .orderedSame
            }
            ?? board.cards.first { $0.title == trimmed }
        guard let target else {
            note("focus_node: no match")
            return false
        }
        board.focus(target.id)
        board.zoomToCard(target.id)
        record(board, action: "Focused a card from a view")
        return true
    }

    private func openURLOnMain(_ url: URL) async -> Bool {
        guard Self.isAllowed(url) else {
            note("open_url refused")
            return false
        }
        let place = url.scheme?.lowercased() == "mailto" ? "your mail app" : (url.host() ?? "")
        let allowed = await askOnMain(
            title: "Open this link?",
            message: "The view wants to open \(place) in your browser or mail app.",
            confirmTitle: "Open", destructive: false)
        guard allowed else { return false }
        let opened = NSWorkspace.shared.open(url)
        if let board { record(board, action: "Opened a link from a view") }
        return opened
    }

    private func askOnMain(title: String, message: String, confirmTitle: String, destructive: Bool)
        async -> Bool
    {
        guard let model else { return false }
        return await model.requestConfirmation(
            GeneratedViewConfirmRequest(
                title: String(title.prefix(120)), message: String(message.prefix(600)),
                confirmTitle: String(confirmTitle.prefix(40)), isDestructive: destructive))
    }

    private func note(_ line: String) {
        model?.appendJournal(line)
    }

    private func record(_ board: CanvasBoardState, action: String) {
        let creator = model?.creatorName ?? "an agent"
        CanvasAgentCenter.shared.record(
            board.id, agent: "User", action: action, outcome: "View shown by \(creator)")
    }
}

/// One confirmation a view asks for. The card shows it as a popup.
struct GeneratedViewConfirmRequest: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let isDestructive: Bool
}
