import AppKit
import CoreGraphics
import Foundation
import RafuCore
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type for items that become Ensemble cards on drop: an
    /// Agent History row, or a Terminals-panel Terminal Group row. It is NOT
    /// the editor-tab type (`rafuEditorDrag`), so editor groups and text
    /// views never see it.
    ///
    /// `conformingTo: .data` is set here AND the identifier is declared in the
    /// app's Info.plist (`UTExportedTypeDeclarations`, see
    /// `script/build_and_run.sh`). A private type that does not conform to
    /// `public.data` is silently dropped by the SwiftUI drag bridge. See
    /// `docs/references/drag-and-drop-custom-uttype.md`.
    nonisolated static let rafuEnsembleDrag = UTType(
        exportedAs: "dev.vatsalsaglani.rafu.ensemble-drag", conformingTo: .data)
}

/// The payload of a drag that ends on an Ensemble board. It carries
/// identifiers only: never a title, a path, or a transcript. It has no public
/// text or file representation, so a drop anywhere else pastes nothing.
nonisolated enum CanvasBoardDragPayload: Codable, Equatable, Sendable {
    case agentSession(provider: AgentHistoryProvider, sessionID: String)
    /// A Terminals-panel Terminal Group row, by id only. Unlike the editor's
    /// own Terminal Group tab drag (which carries an `EditorTabID` over
    /// `rafuEditorDrag`), a panel row can name a PARKED group that has no
    /// editor tab at all, so it needs the group id directly.
    case terminalGroup(id: TerminalGroupID)

    /// A drag item is tiny. Anything larger is not from Rafu.
    static let maximumEncodedBytes = 16 * 1_024

    enum DecodeError: Error, Equatable {
        case tooLarge
        case unsafeIdentifier
    }

    /// The history session this payload names, or `nil` for a
    /// `.terminalGroup` payload.
    var sessionKey: AgentHistorySessionKey? {
        switch self {
        case .agentSession(let provider, let sessionID):
            AgentHistorySessionKey(provider: provider, sessionID: sessionID)
        case .terminalGroup:
            nil
        }
    }

    /// The Terminal Group id this payload names, or `nil` for an
    /// `.agentSession` payload.
    var terminalGroupID: TerminalGroupID? {
        switch self {
        case .terminalGroup(let id): id
        case .agentSession: nil
        }
    }

    init(key: AgentHistorySessionKey) {
        self = .agentSession(provider: key.provider, sessionID: key.sessionID)
    }

    init(terminalGroupID: TerminalGroupID) {
        self = .terminalGroup(id: terminalGroupID)
    }

    func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes bounded data and, for an Agent History session, refuses an id
    /// Rafu would not type into a shell (`AgentHistoryResumeCommand.arguments`
    /// is `nil` for it). A `.terminalGroup` id is only ever a locally
    /// generated `UUID`, so it needs no such content check.
    init(data: Data) throws {
        guard data.count <= Self.maximumEncodedBytes else { throw DecodeError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        if let sessionKey = value.sessionKey {
            guard AgentHistoryResumeCommand.arguments(for: sessionKey) != nil else {
                throw DecodeError.unsafeIdentifier
            }
        }
        self = value
    }

    /// `nil` for any data that is too large, malformed, or unsafe.
    static func decode(_ data: Data) -> CanvasBoardDragPayload? {
        try? CanvasBoardDragPayload(data: data)
    }

    /// Builds an `NSItemProvider` with the payload pre-encoded into `Data`.
    /// This is the same registration as `EditorDragPayload.makeItemProvider`
    /// (same API, `.all` visibility), because that pattern is known to cross
    /// the SwiftUI to AppKit drag bridge. The load handler captures only
    /// immutable `Data`.
    func makeItemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        guard let data = try? encodedData() else { return provider }
        provider.registerDataRepresentation(
            forTypeIdentifier: UTType.rafuEnsembleDrag.identifier,
            visibility: .all
        ) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}

/// Which kind of `rafuEnsembleDrag` a same-window drag is, for the hover
/// preview label only. See `WorkspaceSession.activeEnsembleDragHint`.
nonisolated enum EnsembleDragHint: Sendable {
    case agentSession
    case terminalGroup
}

/// Pure geometry for a drop on the board.
nonisolated enum CanvasBoardDropGeometry {
    /// The board point under a view point. This is the same math as
    /// `WorkspaceSession.addCanvasDroppedFiles`.
    static func boardPoint(_ point: CGPoint, viewport: CanvasViewport) -> CGPoint {
        CGPoint(
            x: (point.x - viewport.x) / viewport.scale,
            y: (point.y - viewport.y) / viewport.scale)
    }

    /// The default card size for `content`: 640×420 for `.terminal`/`.web`,
    /// otherwise `CanvasRect`'s stored default (380×260). Shared by
    /// `CanvasBoardState.add` and the drop preview resolver so a hover ghost
    /// is always the exact size the card will be.
    static func defaultSize(for content: CanvasCardContent) -> CGSize {
        switch content {
        case .terminal, .web: CGSize(width: 640, height: 420)
        default: CGSize(width: CanvasRect().width, height: CanvasRect().height)
        }
    }

    /// The rect `CanvasBoardState.add(title:content:center:)` creates for
    /// `content` when centered at `center` (board units): `defaultSize(for:)`,
    /// centered on `center`, then rounded and clamped to ±50,000 — the same
    /// rule `add` applies.
    static func defaultRect(for content: CanvasCardContent, centeredAt center: CGPoint)
        -> CanvasRect
    {
        let size = defaultSize(for: content)
        var rect = CanvasRect(x: 40, y: 40, width: size.width, height: size.height)
        rect.x = min(50_000, max(-50_000, (Double(center.x) - rect.width / 2).rounded()))
        rect.y = min(50_000, max(-50_000, (Double(center.y) - rect.height / 2).rounded()))
        return rect
    }
}

/// What a drag over the board carries, after decoding. The SwiftUI delegate
/// and the AppKit bridge both produce this value, so the board has one drop
/// policy (`CanvasFileDrop`).
nonisolated enum CanvasBoardDropContent: Equatable, Sendable {
    /// Files from Finder, or from the Files tree (`fromFilesTree`).
    case files([URL], fromFilesTree: Bool)
    /// An Agent History row.
    case agentSession(AgentHistorySessionKey)
    /// An editor tab, by its identifier string.
    case tab(String)
    /// A Terminals-panel Terminal Group row, by id.
    case terminalGroup(TerminalGroupID)
}

/// What a tab dropped on a board becomes.
nonisolated enum CanvasBoardTabDrop {
    enum Decision: Equatable, Sendable {
        /// A one-pane Terminal Group tab dropped in the centre moves onto
        /// the board.
        case moveTerminalToBoard
        /// Everything else is the editor group's own tab drop: an edge band
        /// splits the group, so splitting still works under a visible board.
        case forwardToGroup(EditorSplitEdge?)
    }

    static func decide(edge: EditorSplitEdge?, isTerminalGroupTab: Bool) -> Decision {
        if edge == nil, isTerminalGroupTab { return .moveTerminalToBoard }
        return .forwardToGroup(edge)
    }
}
