import AppKit
import CoreGraphics
import Foundation
import RafuCore
import UniformTypeIdentifiers

extension UTType {
    /// Private drag type for items that become Ensemble cards on drop: today,
    /// an Agent History row. It is NOT the editor-tab type (`rafuEditorDrag`),
    /// so editor groups and text views never see it.
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

    /// A drag item is tiny. Anything larger is not from Rafu.
    static let maximumEncodedBytes = 16 * 1_024

    enum DecodeError: Error, Equatable {
        case tooLarge
        case unsafeIdentifier
    }

    /// The history session this payload names.
    var sessionKey: AgentHistorySessionKey {
        switch self {
        case .agentSession(let provider, let sessionID):
            AgentHistorySessionKey(provider: provider, sessionID: sessionID)
        }
    }

    init(key: AgentHistorySessionKey) {
        self = .agentSession(provider: key.provider, sessionID: key.sessionID)
    }

    func encodedData() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Decodes bounded data and refuses an id that Rafu would not type into
    /// a shell (`AgentHistoryResumeCommand.arguments` is `nil` for it).
    init(data: Data) throws {
        guard data.count <= Self.maximumEncodedBytes else { throw DecodeError.tooLarge }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard AgentHistoryResumeCommand.arguments(for: value.sessionKey) != nil else {
            throw DecodeError.unsafeIdentifier
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

/// Pure geometry for a drop on the board.
nonisolated enum CanvasBoardDropGeometry {
    /// The board point under a view point. This is the same math as
    /// `WorkspaceSession.addCanvasDroppedFiles`.
    static func boardPoint(_ point: CGPoint, viewport: CanvasViewport) -> CGPoint {
        CGPoint(
            x: (point.x - viewport.x) / viewport.scale,
            y: (point.y - viewport.y) / viewport.scale)
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
