import Foundation

/// The `.rafuensemble` file format (X5): one board as versioned JSON that can
/// live in a workspace, be committed, and be opened as a board tab.
///
/// ```json
/// {
///   "format": "dev.rafu.ensemble",
///   "formatVersion": 1,
///   "generator": "Rafu",
///   "board": { "id": "…", "title": "Plan", "revision": 3 },
///   "cards": [ … CanvasCard … ],
///   "connections": [ … CanvasConnection … ],
///   "viewport": { "scale": 1, "x": 0, "y": 0 },
///   "assets": [ { "path": "docs/shot.png", "kind": "image",
///                 "mediaType": "image/png", "data": "<base64, optional>" } ]
/// }
/// ```
///
/// Rules:
/// - Every file and image reference is a workspace-relative path; nothing is
///   absolute, so a committed file opens in another checkout.
/// - `assets` lists each referenced file and image once. An image may carry its
///   bytes (`data`, base64) under the embedded caps in `CanvasLimits`; an
///   export embeds small images so the file still shows them elsewhere.
/// - Terminal layouts are not written: they can contain machine paths, and a
///   terminal never restores a process anyway. Terminal cards stay as cards.
/// - A reader rejects a newer `formatVersion` with `unsupportedVersion`
///   before it decodes anything else, and unknown keys are ignored.
/// - `board.revision` is the expected-version counter. Each save writes
///   `revision + 1` after checking the file still holds the expected revision.
nonisolated struct CanvasEnsembleFile: Codable, Equatable, Sendable {
    static let pathExtension = "rafuensemble"
    static let typeIdentifier = "dev.rafu.ensemble"
    static let formatIdentifier = "dev.rafu.ensemble"
    static let currentFormatVersion = 1

    nonisolated struct Board: Codable, Equatable, Sendable {
        var id: CanvasID
        var title: String
        var revision: UInt64
    }

    nonisolated enum AssetKind: String, Codable, Sendable {
        case image, file
    }

    nonisolated struct Asset: Codable, Equatable, Sendable {
        var path: String
        var kind: AssetKind
        var mediaType: String?
        /// Embedded bytes, base64 in JSON. Images only.
        var data: Data?

        init(path: String, kind: AssetKind, mediaType: String? = nil, data: Data? = nil) {
            self.path = path
            self.kind = kind
            self.mediaType = mediaType
            self.data = data
        }
    }

    var format = Self.formatIdentifier
    var formatVersion = Self.currentFormatVersion
    var generator: String? = "Rafu"
    var board: Board
    var cards: [CanvasCard]
    var connections: [CanvasConnection]
    var viewport: CanvasViewport
    var assets: [Asset]

    /// Builds a file from a board snapshot. `embedded` maps image paths to
    /// their bytes; entries that are not referenced, not a known image type,
    /// or over the caps are left out (the asset keeps its path).
    init(document: CanvasDocument, embedded: [String: Data] = [:]) {
        board = Board(id: document.id, title: document.title, revision: document.revision)
        cards = document.cards
        connections = document.connections
        viewport = document.viewport
        assets = Self.assets(for: document.cards, embedded: embedded)
    }

    /// The asset list for `cards`, in card order, one entry per path.
    static func assets(for cards: [CanvasCard], embedded: [String: Data]) -> [Asset] {
        var seen = Set<String>()
        var result: [Asset] = []
        var embeddedTotal = 0
        for card in cards {
            let asset: Asset
            switch card.content {
            case .image(let path):
                guard seen.insert(path).inserted else { continue }
                var item = Asset(path: path, kind: .image)
                if let data = embedded[path], let type = mediaType(of: data),
                    data.count <= CanvasLimits.embeddedAssetBytes,
                    embeddedTotal + data.count <= CanvasLimits.embeddedAssetsTotalBytes
                {
                    embeddedTotal += data.count
                    item.mediaType = type
                    item.data = data
                }
                asset = item
            case .file(let path):
                guard seen.insert(path).inserted else { continue }
                asset = Asset(path: path, kind: .file)
            default:
                continue
            }
            guard result.count < CanvasLimits.ensembleAssets else { break }
            result.append(asset)
        }
        return result
    }

    /// The image type of `data` from its leading bytes: PNG, JPEG or GIF.
    static func mediaType(of data: Data) -> String? {
        let head = [UInt8](data.prefix(8))
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return "image/png"
        }
        if head.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if head.starts(with: Array("GIF87a".utf8)) || head.starts(with: Array("GIF89a".utf8)) {
            return "image/gif"
        }
        return nil
    }

    /// The board this file describes, validated like a saved board.
    func document() throws -> CanvasDocument {
        var value = CanvasDocument(title: board.title, id: board.id)
        value.revision = board.revision
        value.cards = cards
        value.connections = connections
        value.viewport = viewport
        try value.validate()
        return value
    }

    /// Images whose bytes the file carries, by path.
    var embeddedImages: [String: Data] {
        var result: [String: Data] = [:]
        for asset in assets where asset.kind == .image {
            if let data = asset.data { result[asset.path] = data }
        }
        return result
    }

    func validate() throws {
        guard format == Self.formatIdentifier else { throw CanvasError.invalidDocument }
        guard formatVersion <= Self.currentFormatVersion else {
            throw CanvasError.unsupportedVersion
        }
        guard formatVersion >= 1, board.revision > 0, assets.count <= CanvasLimits.ensembleAssets
        else { throw CanvasError.invalidDocument }
        if let generator {
            guard CanvasStyleDecoding.validText(generator, limit: 120) else {
                throw CanvasError.invalidDocument
            }
        }
        _ = try document()
        var paths = Set<String>()
        var embeddedTotal = 0
        for asset in assets {
            guard CanvasCardContent.validRelativePath(asset.path),
                paths.insert(asset.path).inserted
            else { throw CanvasError.invalidDocument }
            if let mediaType = asset.mediaType {
                guard ["image/png", "image/jpeg", "image/gif"].contains(mediaType) else {
                    throw CanvasError.invalidDocument
                }
            }
            if let data = asset.data {
                embeddedTotal += data.count
                guard asset.kind == .image, data.count <= CanvasLimits.embeddedAssetBytes,
                    embeddedTotal <= CanvasLimits.embeddedAssetsTotalBytes,
                    let type = Self.mediaType(of: data),
                    asset.mediaType == nil || asset.mediaType == type
                else { throw CanvasError.invalidDocument }
            }
        }
    }

    /// Pretty-printed, key-sorted JSON so a committed board diffs cleanly.
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= CanvasLimits.ensembleFileBytes else { throw CanvasError.capacity }
        return data
    }

    private struct Header: Decodable {
        let format: String
        let formatVersion: Int
    }

    /// Decodes and validates a file. The header is read first, so a newer
    /// format version fails as `unsupportedVersion` even when the rest of the
    /// file has a shape this version cannot read.
    static func decode(_ data: Data) throws -> CanvasEnsembleFile {
        guard data.count <= CanvasLimits.ensembleFileBytes else {
            throw CanvasError.invalidDocument
        }
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(Header.self, from: data),
            header.format == formatIdentifier
        else { throw CanvasError.invalidDocument }
        guard header.formatVersion <= currentFormatVersion else {
            throw CanvasError.unsupportedVersion
        }
        let value: CanvasEnsembleFile
        do {
            value = try decoder.decode(CanvasEnsembleFile.self, from: data)
        } catch let error as CanvasError {
            throw error
        } catch {
            throw CanvasError.invalidDocument
        }
        try value.validate()
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case format, formatVersion, generator, board, cards, connections, viewport, assets
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        format = try values.decode(String.self, forKey: .format)
        formatVersion = try values.decode(Int.self, forKey: .formatVersion)
        guard formatVersion <= Self.currentFormatVersion else {
            throw CanvasError.unsupportedVersion
        }
        let cardList = try values.nestedUnkeyedContainer(forKey: .cards)
        let connectionList = try values.nestedUnkeyedContainer(forKey: .connections)
        guard (cardList.count ?? Int.max) <= CanvasLimits.cards,
            (connectionList.count ?? Int.max) <= CanvasLimits.connections
        else { throw CanvasError.invalidDocument }
        generator = try values.decodeIfPresent(String.self, forKey: .generator)
        board = try values.decode(Board.self, forKey: .board)
        cards = try values.decode([CanvasCard].self, forKey: .cards)
        connections = try values.decode([CanvasConnection].self, forKey: .connections)
        viewport = try values.decodeIfPresent(CanvasViewport.self, forKey: .viewport) ?? .init()
        assets = try values.decodeIfPresent([Asset].self, forKey: .assets) ?? []
    }

    /// A 64-bit FNV-1a digest of the file bytes. Not cryptographic: it only
    /// tells whether the file changed since Rafu last read or wrote it.
    static func fingerprint(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
