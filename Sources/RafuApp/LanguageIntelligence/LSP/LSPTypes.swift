import Foundation

// Deviation from the increment-C1 brief: the LSP spec's `Range` type is
// named `LSPRange` here, not `Range`. `Range<Bound>` is a Swift standard
// library type already used unqualified elsewhere in this module (e.g.
// `Sources/RafuApp/Git/IntralineDiff.swift`, `Views/EditorCanvasView.swift`).
// A same-module top-level `struct Range` would shadow `Swift.Range`
// module-wide and break those files' unqualified `Range<Int>` usage.

// MARK: - Handshake

/// Sent as `initialize`'s `clientInfo`.
nonisolated struct ClientInfo: Codable, Sendable {
    let name: String
    let version: String?
}

/// Decoded from `initialize`'s result `serverInfo`, when a server sends one.
nonisolated struct ServerInfo: Codable, Sendable {
    let name: String
    let version: String?
}

/// `general` capabilities this client advertises. Only `positionEncodings`
/// is sent here — `window.workDoneProgress` is advertised via the sibling
/// ``WindowClientCapabilities``, not this type.
nonisolated struct GeneralClientCapabilities: Codable, Sendable {
    let positionEncodings: [String]?
}

/// `window` capabilities this client advertises. `workDoneProgress: true`
/// tells the server it may create work-done-progress tokens via
/// `window/workDoneProgress/create`, which is how servers stream indexing
/// progress ($/progress begin/report/end) that Rafu surfaces as `.indexing`.
nonisolated struct WindowClientCapabilities: Codable, Sendable {
    let workDoneProgress: Bool?
}

/// The full set of client capabilities this session advertises. Deliberately
/// minimal: only the fields the client actually uses.
nonisolated struct ClientCapabilities: Codable, Sendable {
    let general: GeneralClientCapabilities?
    let window: WindowClientCapabilities?
}

/// `initialize`'s request params.
nonisolated struct InitializeParams: Codable, Sendable {
    let processId: Int?
    let clientInfo: ClientInfo?
    let rootUri: String?
    let capabilities: ClientCapabilities
    let initializationOptions: JSONValue?
}

/// `initialize`'s result.
nonisolated struct InitializeResult: Decodable, Sendable {
    let capabilities: ServerCapabilities
    let serverInfo: ServerInfo?
}

/// `initialized`'s (always-empty) notification params.
nonisolated struct InitializedParams: Encodable, Sendable {}

// MARK: - Bool-or-options capability shape

/// A capability that a server may advertise either as a bare `true`/`false`
/// or as an options object (e.g. `{"resolveProvider": true}`). Unknown
/// option fields are ignored by `Options`'s own lenient `Decodable`
/// conformance — this type only distinguishes "off", "on (bare bool)", and
/// "on (with options)".
nonisolated enum BoolOrOptions<Options: Decodable & Sendable>: Decodable, Sendable {
    case flag(Bool)
    case options(Options)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self) {
            self = .flag(value)
            return
        }
        self = .options(try container.decode(Options.self))
    }

    /// A capability is available iff the field decoded at all (non-`nil`)
    /// and `isEnabled` — `.flag(false)` is the one case that decodes but
    /// still means "off".
    var isEnabled: Bool {
        switch self {
        case .flag(let value): return value
        case .options: return true
        }
    }
}

extension BoolOrOptions: Equatable where Options: Equatable {}

/// An options object with no fields C1 needs. Every
/// `definitionProvider`/`declarationProvider`/`referencesProvider`/
/// `hoverProvider`/`documentSymbolProvider` uses this — servers may attach
/// extra option fields (e.g. `workDoneProgress`); they're ignored.
nonisolated struct EmptyOptions: Decodable, Sendable {}

// MARK: - Server capabilities (lenient)

/// Decoded leniently: unknown top-level keys are simply absent from this
/// struct and ignored by `JSONDecoder`, which never fails on unrecognized
/// keys. Only the fields C1 needs are represented.
nonisolated struct ServerCapabilities: Decodable, Sendable {
    let positionEncoding: String?
    let textDocumentSync: TextDocumentSyncSetting?
    let definitionProvider: BoolOrOptions<EmptyOptions>?
    let declarationProvider: BoolOrOptions<EmptyOptions>?
    let referencesProvider: BoolOrOptions<EmptyOptions>?
    let hoverProvider: BoolOrOptions<EmptyOptions>?
    let documentSymbolProvider: BoolOrOptions<EmptyOptions>?
}

/// `textDocument/synchronization`'s `TextDocumentSyncKind`. Raw `Int` per
/// the LSP spec (`none = 0`, `full = 1`, `incremental = 2`).
nonisolated enum TextDocumentSyncKind: Int, Codable, Sendable {
    case none = 0
    case full = 1
    case incremental = 2
}

/// The object form of `textDocumentSync`.
nonisolated struct TextDocumentSyncOptions: Codable, Sendable {
    let openClose: Bool?
    let change: TextDocumentSyncKind?
}

/// `textDocumentSync` may be a bare `TextDocumentSyncKind` (older servers)
/// or a `TextDocumentSyncOptions` object (current spec).
nonisolated enum TextDocumentSyncSetting: Decodable, Sendable {
    case kind(TextDocumentSyncKind)
    case options(TextDocumentSyncOptions)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let rawValue = try? container.decode(Int.self),
            let kind = TextDocumentSyncKind(rawValue: rawValue)
        {
            self = .kind(kind)
            return
        }
        self = .options(try container.decode(TextDocumentSyncOptions.self))
    }

    /// The negotiated sync kind, defaulting a bare kind's absence of nuance
    /// (there is none — a bare `TextDocumentSyncKind` is unambiguous) and an
    /// options object's missing `change` to `.none`.
    var effectiveKind: TextDocumentSyncKind {
        switch self {
        case .kind(let kind): return kind
        case .options(let options): return options.change ?? .none
        }
    }

    /// Whether the server wants `didOpen`/`didClose` notifications. Per the
    /// LSP spec an omitted `openClose` (and a bare-kind sync setting, which
    /// carries no `openClose` at all) defaults to `true`.
    var openClose: Bool {
        switch self {
        case .kind: return true
        case .options(let options): return options.openClose ?? true
        }
    }
}

// MARK: - Position, range, location

/// A zero-based line/character position. `character`'s unit depends on the
/// negotiated `PositionEncoding` — see `DocumentTextMirror`.
nonisolated struct Position: Codable, Sendable, Equatable {
    let line: Int
    let character: Int
}

/// A half-open `[start, end)` span, spelled `LSPRange` to avoid shadowing
/// `Swift.Range` module-wide (see the file-top note).
nonisolated struct LSPRange: Codable, Sendable, Equatable {
    let start: Position
    let end: Position
}

nonisolated struct Location: Codable, Sendable, Equatable {
    let uri: String
    let range: LSPRange
}

/// `textDocument/definition`/`declaration`'s richer link shape. Only the
/// fields C1 needs to fold a link into a `Location` are represented —
/// `originSelectionRange` (if the server sends one) is ignored.
nonisolated struct LocationLink: Decodable, Sendable, Equatable {
    let targetUri: String
    let targetRange: LSPRange
    let targetSelectionRange: LSPRange
}

nonisolated struct TextDocumentIdentifier: Codable, Sendable, Equatable {
    let uri: String
}

nonisolated struct VersionedTextDocumentIdentifier: Codable, Sendable, Equatable {
    let uri: String
    let version: Int
}

nonisolated struct TextDocumentItem: Codable, Sendable, Equatable {
    let uri: String
    let languageId: String
    let version: Int
    let text: String
}

nonisolated struct TextDocumentPositionParams: Codable, Sendable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
}

// MARK: - Synchronization notifications

nonisolated struct DidOpenTextDocumentParams: Codable, Sendable, Equatable {
    let textDocument: TextDocumentItem
}

// `Encodable`-only, not full `Codable`: `TextDocumentContentChangeEvent` is
// client-to-server only (see its own doc comment), so nothing ever decodes
// this shape.
nonisolated struct DidChangeTextDocumentParams: Encodable, Sendable, Equatable {
    let textDocument: VersionedTextDocumentIdentifier
    let contentChanges: [TextDocumentContentChangeEvent]
}

nonisolated struct DidCloseTextDocumentParams: Codable, Sendable, Equatable {
    let textDocument: TextDocumentIdentifier
}

/// Encodes either `{range, text}` (incremental sync) or `{text}` (full-text
/// sync) — the two wire shapes `TextDocumentContentChangeEvent` may take.
/// Client-to-server only, so only `Encodable`; nothing decodes this shape.
nonisolated enum TextDocumentContentChangeEvent: Encodable, Sendable, Equatable {
    case incremental(range: LSPRange, text: String)
    case full(text: String)

    private enum CodingKeys: String, CodingKey {
        case range
        case text
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .incremental(let range, let text):
            try container.encode(range, forKey: .range)
            try container.encode(text, forKey: .text)
        case .full(let text):
            try container.encode(text, forKey: .text)
        }
    }
}

// MARK: - Request params

nonisolated struct ReferenceContext: Codable, Sendable, Equatable {
    let includeDeclaration: Bool
}

nonisolated struct ReferenceParams: Codable, Sendable, Equatable {
    let textDocument: TextDocumentIdentifier
    let position: Position
    let context: ReferenceContext
}

nonisolated struct DocumentSymbolParams: Codable, Sendable, Equatable {
    let textDocument: TextDocumentIdentifier
}

// MARK: - Nullable result unions

/// `textDocument/definition`/`declaration`/`references`'s result: a single
/// `Location`, an array of `Location`, an array of `LocationLink`, or `null`
/// (no result — a legal, non-error answer). `init(from:)` checks `null`
/// first so a legitimate empty answer decodes successfully instead of
/// falling through to a decode failure.
nonisolated enum LocationsResult: Decodable, Sendable {
    case none
    case single(Location)
    case array([Location])
    case links([LocationLink])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        if let location = try? container.decode(Location.self) {
            self = .single(location)
            return
        }
        if let locations = try? container.decode([Location].self) {
            self = .array(locations)
            return
        }
        if let links = try? container.decode([LocationLink].self) {
            self = .links(links)
            return
        }
        throw DecodingError.dataCorrupted(
            DecodingError.Context(
                codingPath: container.codingPath,
                debugDescription: "Unsupported definition/declaration/references result shape"
            )
        )
    }

    /// `LocationLink`s fold to `Location` via `targetRange` (not
    /// `targetSelectionRange` — the caret should land on the full target
    /// span, matching plain `Location` results from the same request).
    var locations: [Location] {
        switch self {
        case .none: return []
        case .single(let location): return [location]
        case .array(let locations): return locations
        case .links(let links):
            return links.map { Location(uri: $0.targetUri, range: $0.targetRange) }
        }
    }
}

nonisolated struct MarkupContent: Decodable, Sendable, Equatable {
    let kind: String
    let value: String
}

/// The deprecated (but still emitted by some servers) `MarkedString` shape:
/// either a bare Markdown string or `{language, value}`.
nonisolated enum MarkedString: Decodable, Sendable, Equatable {
    case plain(String)
    case languageValue(language: String, value: String)

    private struct Object: Decodable {
        let language: String
        let value: String
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .plain(text)
            return
        }
        let object = try container.decode(Object.self)
        self = .languageValue(language: object.language, value: object.value)
    }
}

/// `Hover.contents`, tolerant of every shape the LSP spec allows across its
/// versions: a `MarkupContent` object, a single `MarkedString`, or an array
/// of `MarkedString`. Order matters: `MarkupContent` is tried first because
/// it's the only shape requiring a `kind` key, so a `{language, value}`
/// `MarkedString` object can never be misread as one.
nonisolated enum HoverContents: Decodable, Sendable, Equatable {
    case markup(MarkupContent)
    case markedStrings([MarkedString])
    case markedString(MarkedString)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let markup = try? container.decode(MarkupContent.self) {
            self = .markup(markup)
            return
        }
        if let strings = try? container.decode([MarkedString].self) {
            self = .markedStrings(strings)
            return
        }
        self = .markedString(try container.decode(MarkedString.self))
    }
}

nonisolated struct Hover: Decodable, Sendable, Equatable {
    let contents: HoverContents
    let range: LSPRange?
}

/// `textDocument/hover`'s result: a `Hover`, or `null` (no hover info at
/// this position — a legal, non-error answer).
nonisolated enum HoverResult: Decodable, Sendable {
    case none
    case hover(Hover)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        self = .hover(try container.decode(Hover.self))
    }
}

/// `textDocument/documentSymbol`'s minimal fields: name, an untyped `kind`
/// (the raw `SymbolKind` integer — C1 doesn't render an icon from it yet),
/// its full range, its narrower `selectionRange`, and nested children.
nonisolated struct DocumentSymbol: Decodable, Sendable, Equatable {
    let name: String
    let kind: Int
    let range: LSPRange
    let selectionRange: LSPRange
    let children: [DocumentSymbol]?
}

/// The flat, pre-hierarchical `SymbolInformation` shape some servers still
/// return instead of `DocumentSymbol`.
nonisolated struct SymbolInformation: Decodable, Sendable, Equatable {
    let name: String
    let kind: Int
    let location: Location
}

/// `textDocument/documentSymbol`'s result: hierarchical `DocumentSymbol`s,
/// flat `SymbolInformation`s, or `null` (no symbols — a legal, non-error
/// answer). Order matters: `DocumentSymbol` is tried first because it's the
/// only shape requiring `range`/`selectionRange` keys, which
/// `SymbolInformation` (whose position lives in `location`) never has.
nonisolated enum DocumentSymbolResult: Decodable, Sendable {
    case none
    case documentSymbols([DocumentSymbol])
    case symbolInformation([SymbolInformation])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .none
            return
        }
        if let symbols = try? container.decode([DocumentSymbol].self) {
            self = .documentSymbols(symbols)
            return
        }
        self = .symbolInformation(try container.decode([SymbolInformation].self))
    }
}

// MARK: - $/progress

/// A `$/progress` token: either an integer or a string.
nonisolated enum ProgressToken: Decodable, Sendable, Equatable {
    case number(Int)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

nonisolated struct ProgressParams<Value: Decodable & Sendable>: Decodable, Sendable {
    let token: ProgressToken
    let value: Value
}

nonisolated struct WorkDoneProgressBegin: Decodable, Sendable, Equatable {
    let kind: String
    let title: String?
    let message: String?
    let percentage: Int?
}

nonisolated struct WorkDoneProgressReport: Decodable, Sendable, Equatable {
    let kind: String
    let message: String?
    let percentage: Int?
}

nonisolated struct WorkDoneProgressEnd: Decodable, Sendable, Equatable {
    let kind: String
    let message: String?
}

/// `$/progress`'s `value` payload, discriminated by its `kind` string
/// (`"begin"`/`"report"`/`"end"`) rather than by trying each shape in turn —
/// all three share several optional field names, so shape-probing would be
/// ambiguous.
nonisolated enum WorkDoneProgressValue: Decodable, Sendable, Equatable {
    case begin(WorkDoneProgressBegin)
    case report(WorkDoneProgressReport)
    case end(WorkDoneProgressEnd)

    private struct KindProbe: Decodable {
        let kind: String
    }

    init(from decoder: Decoder) throws {
        let probe = try KindProbe(from: decoder)
        switch probe.kind {
        case "begin":
            self = .begin(try WorkDoneProgressBegin(from: decoder))
        case "report":
            self = .report(try WorkDoneProgressReport(from: decoder))
        case "end":
            self = .end(try WorkDoneProgressEnd(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown $/progress kind '\(probe.kind)'"
                )
            )
        }
    }
}

// MARK: - Position encoding negotiation

/// The negotiated unit for `Position.character`. Rafu always offers
/// `["utf-16", "utf-8"]` (in that preference order — UTF-16 is native to
/// `NSTextStorage`/TextKit) and honors whatever the server picks back in
/// `ServerCapabilities.positionEncoding`.
nonisolated enum PositionEncoding: Sendable, Equatable {
    case utf16
    case utf8

    /// `rawLSPValue` is `ServerCapabilities.positionEncoding`. Absent (a
    /// server that predates position-encoding negotiation) or unrecognized
    /// defaults to `.utf16` — LSP's own historical default.
    init(rawLSPValue: String?) {
        switch rawLSPValue {
        case "utf-8": self = .utf8
        case "utf-16": self = .utf16
        default: self = .utf16
        }
    }
}

// MARK: - Document text mirror

/// A local shadow copy of one open document's text plus a cached line-start
/// table, used only to translate between `EditorDocument`'s native UTF-16
/// offsets and the negotiated `PositionEncoding`'s `Position`. Never the
/// document's authoritative content — `NSTextStorage` owns that; this is a
/// throwaway copy `LanguageServerSession` keeps in sync via `didOpen`/
/// `didChange`/`resync`.
nonisolated struct DocumentTextMirror: Sendable {
    private(set) var text: String
    /// The UTF-16 offset of the start of each line. Line 0 starts at 0;
    /// every subsequent entry is one UTF-16 unit past a `\n` (a `\r` in a
    /// `\r\n` pair stays part of the preceding line).
    private(set) var lineStartsUTF16: [Int]
    /// Each line start's `String.Index`, captured directly from the same
    /// `unicodeScalars` walk that builds `lineStartsUTF16` — always a valid
    /// scalar boundary. Kept alongside the UTF-16 offsets so `.utf8`
    /// conversions never need to reconstruct a `String.Index` from a raw
    /// `Int` offset (the standard library has no infallible — or even
    /// failable-but-correct — way to do that walk-free).
    private(set) var lineStartIndices: [String.Index]
    private(set) var totalUTF16Length: Int

    init(text: String) {
        self.text = text
        let table = Self.computeLineStarts(for: text)
        self.lineStartsUTF16 = table.offsets
        self.lineStartIndices = table.indices
        self.totalUTF16Length = table.totalLength
    }

    /// Rebuilds the line table for a new full text. O(n) — acceptable for
    /// C1's document sizes; revisit only if profiling says otherwise.
    mutating func replace(with newText: String) {
        text = newText
        let table = Self.computeLineStarts(for: newText)
        lineStartsUTF16 = table.offsets
        lineStartIndices = table.indices
        totalUTF16Length = table.totalLength
    }

    private static func computeLineStarts(for text: String)
        -> (offsets: [Int], indices: [String.Index], totalLength: Int)
    {
        var offsets = [0]
        var indices = [text.startIndex]
        var utf16Offset = 0
        var index = text.startIndex
        while index < text.endIndex {
            let scalar = text.unicodeScalars[index]
            utf16Offset += Unicode.UTF16.width(scalar)
            index = text.unicodeScalars.index(after: index)
            if scalar == "\n" {
                offsets.append(utf16Offset)
                indices.append(index)
            }
        }
        return (offsets, indices, utf16Offset)
    }

    /// Converts a global UTF-16 offset (as `NSTextStorage`/`EditorDocument`
    /// address text) into a `Position` in `encoding`. `nil` for an
    /// out-of-bounds offset or (in `.utf8`) one that lands inside a
    /// multi-UTF-16-unit scalar, where no UTF-8-byte `character` value can
    /// represent it exactly.
    func position(forUTF16Offset offset: Int, encoding: PositionEncoding) -> Position? {
        guard offset >= 0, offset <= totalUTF16Length else { return nil }
        let lineIndex = lineIndex(forUTF16Offset: offset)
        let lineStart = lineStartsUTF16[lineIndex]
        let relativeOffset = offset - lineStart
        switch encoding {
        case .utf16:
            return Position(line: lineIndex, character: relativeOffset)
        case .utf8:
            guard
                let character = Self.utf8ByteOffset(
                    fromUTF16Offset: relativeOffset, from: lineStartIndices[lineIndex], in: text)
            else { return nil }
            return Position(line: lineIndex, character: character)
        }
    }

    /// The inverse of `position(forUTF16Offset:encoding:)`. `nil` for an
    /// out-of-range line/character or (in `.utf8`) a `character` byte offset
    /// that lands inside a multi-byte scalar.
    func utf16Offset(for position: Position, encoding: PositionEncoding) -> Int? {
        guard position.line >= 0, position.line < lineStartsUTF16.count, position.character >= 0
        else { return nil }
        let lineStart = lineStartsUTF16[position.line]
        let lineEnd =
            position.line + 1 < lineStartsUTF16.count
            ? lineStartsUTF16[position.line + 1] : totalUTF16Length
        switch encoding {
        case .utf16:
            let offset = lineStart + position.character
            guard offset <= lineEnd else { return nil }
            return offset
        case .utf8:
            let lineStartIndex = lineStartIndices[position.line]
            let lineEndIndex =
                position.line + 1 < lineStartIndices.count
                ? lineStartIndices[position.line + 1] : text.endIndex
            guard
                let relativeUTF16 = Self.utf16Offset(
                    fromUTF8ByteOffset: position.character, from: lineStartIndex, to: lineEndIndex,
                    in: text)
            else { return nil }
            return lineStart + relativeUTF16
        }
    }

    /// Binary search for the greatest line-start offset `<= offset`.
    private func lineIndex(forUTF16Offset offset: Int) -> Int {
        var low = 0
        var high = lineStartsUTF16.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStartsUTF16[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low
    }

    /// Walks `unicodeScalars` from `lineStartIndex`, accumulating UTF-16 and
    /// UTF-8 lengths together (an astral scalar always crosses both units
    /// atomically: 2 UTF-16 units, 4 UTF-8 bytes), until the UTF-16
    /// accumulator reaches `targetUTF16Offset`. Returns `nil` if the target
    /// falls strictly inside a scalar's UTF-16 span instead of exactly on a
    /// boundary.
    private static func utf8ByteOffset(
        fromUTF16Offset targetUTF16Offset: Int, from lineStartIndex: String.Index, in text: String
    ) -> Int? {
        var utf16Accumulator = 0
        var utf8Accumulator = 0
        for scalar in text.unicodeScalars[lineStartIndex...] {
            if utf16Accumulator == targetUTF16Offset { return utf8Accumulator }
            let utf16Width = Unicode.UTF16.width(scalar)
            let utf8Width = Unicode.UTF8.width(scalar)
            if utf16Accumulator + utf16Width > targetUTF16Offset { return nil }
            utf16Accumulator += utf16Width
            utf8Accumulator += utf8Width
        }
        return utf16Accumulator == targetUTF16Offset ? utf8Accumulator : nil
    }

    /// The reverse of `utf8ByteOffset(fromUTF16Offset:from:in:)`: walks
    /// `unicodeScalars` in `[lineStartIndex, lineEndIndex)` accumulating both
    /// lengths until the UTF-8 accumulator reaches `targetUTF8ByteOffset`.
    /// Bounded by `lineEndIndex` so a byte offset from a different line can
    /// never be mistaken for a boundary further down the document.
    private static func utf16Offset(
        fromUTF8ByteOffset targetUTF8ByteOffset: Int, from lineStartIndex: String.Index,
        to lineEndIndex: String.Index, in text: String
    ) -> Int? {
        var utf16Accumulator = 0
        var utf8Accumulator = 0
        for scalar in text.unicodeScalars[lineStartIndex..<lineEndIndex] {
            if utf8Accumulator == targetUTF8ByteOffset { return utf16Accumulator }
            let utf16Width = Unicode.UTF16.width(scalar)
            let utf8Width = Unicode.UTF8.width(scalar)
            if utf8Accumulator + utf8Width > targetUTF8ByteOffset { return nil }
            utf16Accumulator += utf16Width
            utf8Accumulator += utf8Width
        }
        return utf8Accumulator == targetUTF8ByteOffset ? utf16Accumulator : nil
    }
}

// MARK: - `file://` URI helpers

/// `path` → `file://`-scheme URI, percent-encoding reserved characters
/// (spaces, non-ASCII, etc.) the way every LSP server expects a document
/// URI to arrive.
nonisolated func fileURI(forPath path: String) -> String {
    URL(fileURLWithPath: path).absoluteString
}

/// The inverse of `fileURI(forPath:)`: percent-decodes a `file://` URI back
/// to a plain path. `nil` for a non-file-scheme or malformed URI.
nonisolated func filePath(forURI uri: String) -> String? {
    guard let url = URL(string: uri), url.isFileURL else { return nil }
    return url.path
}
