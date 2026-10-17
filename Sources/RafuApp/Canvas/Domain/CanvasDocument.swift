import Foundation

nonisolated struct CanvasID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

nonisolated struct CanvasCardID: RawRepresentable, Codable, Hashable, Sendable {
    let rawValue: UUID
    init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

nonisolated enum CanvasLimits {
    static let boards = 10
    static let cards = 100
    static let connections = 200
    static let noteBytes = 64 * 1_024
    static let documentBytes = 2 * 1_024 * 1_024
    static let webSurfaces = 2
    static let captureStreams = 2
}

nonisolated enum CanvasError: Error, LocalizedError, Equatable, Sendable {
    case invalidDocument, unsupportedVersion, capacity, conflict, busy, unavailable
    case invalidURL, invalidPath, noteTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidDocument: "This Canvas contains invalid or excessive data."
        case .unsupportedVersion: "This Canvas needs a newer version of Rafu."
        case .capacity: "The Canvas resource limit has been reached."
        case .conflict: "This Canvas changed in another window. Reload it or save a copy."
        case .busy: "The Canvas store is busy. Try saving again."
        case .unavailable: "The saved Canvas is unavailable."
        case .invalidURL:
            "Use an http or https URL on localhost, 127.0.0.1, or [::1], without credentials."
        case .invalidPath: "Choose a file inside this workspace."
        case .noteTooLarge: "A Canvas note can contain at most 64 KiB of UTF-8 text."
        }
    }
}

nonisolated struct CanvasRect: Codable, Equatable, Sendable {
    var x: Double = 40
    var y: Double = 40
    var width: Double = 380
    var height: Double = 260

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite)
            && abs(x) <= 50_000 && abs(y) <= 50_000
            && (240...2_000).contains(width) && (160...2_000).contains(height)
    }
}

nonisolated struct CanvasViewport: Codable, Equatable, Sendable {
    var scale: Double = 1
    var x: Double = 0
    var y: Double = 0

    var isValid: Bool {
        [scale, x, y].allSatisfy(\.isFinite) && (0.25...2).contains(scale)
            && abs(x) <= 100_000 && abs(y) <= 100_000
    }
}

nonisolated struct CanvasWebDestination: Codable, Equatable, Sendable {
    let address: String

    init(_ input: String) throws {
        guard
            var parts = URLComponents(
                string: input.trimmingCharacters(in: .whitespacesAndNewlines)),
            let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
            let host = parts.host?.lowercased(),
            ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host),
            parts.user == nil, parts.password == nil,
            parts.port.map({ (1...65_535).contains($0) }) ?? true
        else { throw CanvasError.invalidURL }
        parts.scheme = scheme
        parts.host = host
        parts.query = nil
        parts.fragment = nil
        if parts.path.isEmpty { parts.path = "/" }
        guard let url = parts.url, url.absoluteString.utf8.count <= 2_048 else {
            throw CanvasError.invalidURL
        }
        address = url.absoluteString
    }

    var url: URL? { URL(string: address) }

    func permitsNavigation(to candidate: URL) -> Bool {
        guard let url, let other = try? CanvasWebDestination(candidate.absoluteString),
            let otherURL = other.url
        else { return false }
        let a = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let b = URLComponents(url: otherURL, resolvingAgainstBaseURL: false)
        let defaultPort = url.scheme == "https" ? 443 : 80
        return a?.scheme == b?.scheme && a?.host == b?.host
            && (a?.port ?? defaultPort) == (b?.port ?? defaultPort)
    }

    func validate() throws {
        guard try Self(address).address == address else { throw CanvasError.invalidURL }
    }
}

nonisolated enum CanvasCardContent: Codable, Equatable, Sendable {
    case file(path: String)
    case image(path: String)
    /// A persisted snapshot only. A native text storage owns live note edits.
    case note(snapshot: String)
    case terminal(groupID: TerminalGroupID)
    case web(destination: CanvasWebDestination)
    case nativeApp(bundleID: String)

    var kindName: String {
        switch self {
        case .file: "File"
        case .image: "Image"
        case .note: "Note"
        case .terminal: "Terminal"
        case .web: "Local Web App"
        case .nativeApp: "Native App"
        }
    }

    var symbol: String {
        switch self {
        case .file: "doc.text"
        case .image: "photo"
        case .note: "note.text"
        case .terminal: "terminal"
        case .web: "globe"
        case .nativeApp: "macwindow"
        }
    }

    func validate() throws {
        switch self {
        case .file(let path), .image(let path):
            guard Self.validRelativePath(path) else { throw CanvasError.invalidPath }
        case .note(let text):
            guard text.utf8.count <= CanvasLimits.noteBytes else { throw CanvasError.noteTooLarge }
        case .web(let destination): try destination.validate()
        case .nativeApp(let id):
            guard !id.isEmpty, id.utf8.count <= 255,
                id.unicodeScalars.allSatisfy({
                    CharacterSet(
                        charactersIn:
                            "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"
                    ).contains($0)
                })
            else { throw CanvasError.invalidDocument }
        case .terminal: break
        }
    }

    static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && path.utf8.count <= 4_096 && !path.hasPrefix("/")
            && !path.contains("\0")
            && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                !$0.isEmpty && $0 != "." && $0 != ".."
            }
    }
}

nonisolated struct CanvasCard: Codable, Equatable, Identifiable, Sendable {
    var id = CanvasCardID()
    var title: String
    var rect = CanvasRect()
    var content: CanvasCardContent
}

nonisolated enum CanvasConnectionBehavior: String, Codable, CaseIterable, Sendable {
    case related
}

nonisolated struct CanvasConnection: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var from: CanvasCardID
    var to: CanvasCardID
    var label = "Related to"
    var behavior: CanvasConnectionBehavior = .related

    init(
        id: UUID = UUID(), from: CanvasCardID, to: CanvasCardID,
        label: String = "Related to", behavior: CanvasConnectionBehavior = .related
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.label = label
        self.behavior = behavior
    }

    private enum CodingKeys: CodingKey { case id, from, to, label, behavior }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        from = try values.decode(CanvasCardID.self, forKey: .from)
        to = try values.decode(CanvasCardID.self, forKey: .to)
        label = try values.decode(String.self, forKey: .label)
        behavior =
            try values.decodeIfPresent(CanvasConnectionBehavior.self, forKey: .behavior) ?? .related
    }
}

nonisolated struct CanvasDocument: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    var id = CanvasID()
    var revision: UInt64 = 0
    var title: String
    var cards: [CanvasCard] = []
    var connections: [CanvasConnection] = []
    var viewport = CanvasViewport()
    var terminalGroups: TerminalGroupWorkspaceRestoration?

    init(title: String, id: CanvasID = CanvasID()) {
        self.title = title
        self.id = id
    }

    private enum CodingKeys: CodingKey {
        case version, id, revision, title, cards, connections, viewport, terminalGroups
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        guard version == 1 else { throw CanvasError.unsupportedVersion }
        let cardArray = try container.nestedUnkeyedContainer(forKey: .cards)
        let connectionArray = try container.nestedUnkeyedContainer(forKey: .connections)
        guard (cardArray.count ?? Int.max) <= CanvasLimits.cards,
            (connectionArray.count ?? Int.max) <= CanvasLimits.connections
        else { throw CanvasError.invalidDocument }
        id = try container.decode(CanvasID.self, forKey: .id)
        revision = try container.decode(UInt64.self, forKey: .revision)
        title = try container.decode(String.self, forKey: .title)
        cards = try container.decode([CanvasCard].self, forKey: .cards)
        connections = try container.decode([CanvasConnection].self, forKey: .connections)
        viewport = try container.decode(CanvasViewport.self, forKey: .viewport)
        terminalGroups = try container.decodeIfPresent(
            TerminalGroupWorkspaceRestoration.self, forKey: .terminalGroups)
        try validate()
    }

    func validate() throws {
        guard version == 1 else { throw CanvasError.unsupportedVersion }
        guard Self.validTitle(title), cards.count <= CanvasLimits.cards,
            connections.count <= CanvasLimits.connections, viewport.isValid,
            Set(cards.map(\.id)).count == cards.count,
            Set(connections.map(\.id)).count == connections.count
        else { throw CanvasError.invalidDocument }
        for card in cards {
            guard Self.validTitle(card.title), card.rect.isValid else {
                throw CanvasError.invalidDocument
            }
            try card.content.validate()
        }
        let ids = Set(cards.map(\.id))
        guard
            connections.allSatisfy({
                $0.from != $0.to && ids.contains($0.from) && ids.contains($0.to)
                    && Self.validTitle($0.label)
            })
        else { throw CanvasError.invalidDocument }
    }

    static func validTitle(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && text.unicodeScalars.count <= 120
            && !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
}

nonisolated struct CanvasSummary: Identifiable, Equatable, Sendable {
    let id: CanvasID
    let title: String
    let revision: UInt64
}
