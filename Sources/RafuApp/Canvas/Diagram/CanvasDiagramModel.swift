import Foundation

// Diagram value types (workstream X9). X5 stores two of them in
// `CanvasCardContent` as `.frame(CanvasFrame)` and
// `.serviceIcon(CanvasServiceIcon)`; everything else here describes icon packs.

nonisolated enum CanvasDiagramLimits {
    /// Frame title and service icon label, in Unicode scalars.
    static let textScalars = 120
    /// Pack and icon identifiers, in UTF-8 bytes.
    static let identifierBytes = 160
    static let keywordsPerIcon = 24
    static let keywordBytes = 64
    /// Imported packs, not counting the built-in Common pack.
    static let importedPacks = 12
    static let iconsPerPack = 6_000
    static let iconFileBytes = 2 * 1_024 * 1_024
    static let packBytes: Int64 = 300 * 1_024 * 1_024
    static let archiveBytes: Int64 = 1_024 * 1_024 * 1_024
    static let archiveUncompressedBytes: Int64 = 2 * 1_024 * 1_024 * 1_024
    static let archiveEntries = 60_000
    static let scannedFiles = 60_000
}

nonisolated enum CanvasDiagramError: Error, LocalizedError, Equatable, Sendable {
    case invalidValue
    case noWorkspace
    case boardUnavailable
    case nothingToExport
    case outsideWorkspace
    case renderFailed
    case unsupportedSource
    case unsafeArchive
    case archiveTooLarge
    case noIcons
    case packLimit
    case extractionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .invalidValue: "The diagram item contains invalid or excessive data."
        case .noWorkspace: "Open a workspace folder first."
        case .boardUnavailable: "The Canvas is not open."
        case .nothingToExport: "There is nothing to export. Select cards or add a frame."
        case .outsideWorkspace: "Exports must stay inside the workspace folder."
        case .renderFailed: "The export could not be rendered."
        case .unsupportedSource: "Choose a .zip file or a folder of SVG or PNG icons."
        case .unsafeArchive: "The archive contains unsafe paths and was not imported."
        case .archiveTooLarge: "The icon pack is too large to import."
        case .noIcons: "No SVG or PNG icons were found."
        case .packLimit: "Too many icon packs are installed. Remove one first."
        case .extractionFailed(let status): "The archive could not be extracted (status \(status))."
        }
    }
}

/// The tint of a frame. Tints group, they do not carry meaning, so none of them
/// is the accent (gold is for focus, selection and live state only).
nonisolated enum CanvasFrameStyle: String, Codable, CaseIterable, Hashable, Sendable {
    case neutral
    case blue
    case green
    case orange

    var title: String {
        switch self {
        case .neutral: "Grey"
        case .blue: "Blue"
        case .green: "Green"
        case .orange: "Orange"
        }
    }
}

/// A titled region drawn behind its member cards. Moving the frame moves them.
nonisolated struct CanvasFrame: Codable, Equatable, Hashable, Sendable {
    var title: String
    var memberIDs: [CanvasCardID]
    var style: CanvasFrameStyle

    init(title: String, memberIDs: [CanvasCardID] = [], style: CanvasFrameStyle = .neutral) {
        self.title = title
        self.memberIDs = memberIDs
        self.style = style
    }

    private enum CodingKeys: CodingKey { case title, memberIDs, style }

    /// An unknown style from a newer build reads as `.neutral`.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        title = try values.decode(String.self, forKey: .title)
        let members = try values.nestedUnkeyedContainer(forKey: .memberIDs)
        guard (members.count ?? Int.max) <= CanvasLimits.cards else {
            throw CanvasDiagramError.invalidValue
        }
        memberIDs = try values.decode([CanvasCardID].self, forKey: .memberIDs)
        let raw = try values.decodeIfPresent(String.self, forKey: .style)
        style = raw.flatMap(CanvasFrameStyle.init(rawValue:)) ?? .neutral
    }

    func validate() throws {
        guard CanvasDiagramText.isValid(title, allowsEmpty: false),
            memberIDs.count <= CanvasLimits.cards,
            Set(memberIDs).count == memberIDs.count
        else { throw CanvasDiagramError.invalidValue }
    }
}

/// One icon from a pack with a label below it.
nonisolated struct CanvasServiceIcon: Codable, Equatable, Hashable, Sendable {
    var packID: String
    var iconID: String
    var label: String

    func validate() throws {
        guard CanvasDiagramText.isIdentifier(packID), CanvasDiagramText.isIdentifier(iconID),
            CanvasDiagramText.isValid(label, allowsEmpty: true)
        else { throw CanvasDiagramError.invalidValue }
    }
}

nonisolated enum CanvasDiagramText {
    static func isValid(_ text: String, allowsEmpty: Bool) -> Bool {
        let trimmedEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if trimmedEmpty && !allowsEmpty { return false }
        return text.unicodeScalars.count <= CanvasDiagramLimits.textScalars
            && !text.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    /// Lowercase letters, digits, `.`, `-` and `_`; 1 to 160 bytes.
    static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= CanvasDiagramLimits.identifierBytes
            && text.utf8.allSatisfy { byte in
                (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                    || byte == 0x2D || byte == 0x2E || byte == 0x5F
            }
    }

    /// A lowercase identifier from free text: "Amazon EC2" -> "amazon-ec2".
    static func slug(_ text: String) -> String {
        var result = ""
        var pendingDash = false
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        for scalar in folded.lowercased().unicodeScalars {
            let isAlphanumeric =
                (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isAlphanumeric {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        let bounded = String(result.prefix(120))
        return bounded.isEmpty ? "icon" : bounded
    }
}

// MARK: Icon packs

nonisolated enum CanvasIconPackVendor: String, Codable, CaseIterable, Hashable, Sendable {
    case common
    case aws
    case azure
    case googleCloud
    case custom

    var title: String {
        switch self {
        case .common: "Common"
        case .aws: "AWS"
        case .azure: "Azure"
        case .googleCloud: "Google Cloud"
        case .custom: "Custom"
        }
    }

    /// The installed pack identifier. Re-importing a vendor replaces its pack.
    var packID: String {
        switch self {
        case .common: "common"
        case .aws: "aws"
        case .azure: "azure"
        case .googleCloud: "google-cloud"
        case .custom: "custom"
        }
    }

    /// Where the user downloads the official icons. Rafu does not redistribute them.
    var downloadPage: URL? {
        switch self {
        case .aws: URL(string: "https://aws.amazon.com/architecture/icons/")
        case .azure: URL(string: "https://learn.microsoft.com/en-us/azure/architecture/icons/")
        case .googleCloud: URL(string: "https://cloud.google.com/icons")
        case .common, .custom: nil
        }
    }
}

/// One icon in a pack. Built-in icons name an SF Symbol; imported icons name a
/// file inside the pack's `icons` folder.
nonisolated struct CanvasIconPackEntry: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var category: String
    var keywords: [String] = []
    var symbol: String?
    var file: String?

    func validate() throws {
        guard CanvasDiagramText.isIdentifier(id),
            CanvasDiagramText.isValid(name, allowsEmpty: false),
            CanvasDiagramText.isValid(category, allowsEmpty: true),
            keywords.count <= CanvasDiagramLimits.keywordsPerIcon,
            keywords.allSatisfy({ $0.utf8.count <= CanvasDiagramLimits.keywordBytes }),
            symbol.map({ !$0.isEmpty && $0.utf8.count <= 100 }) ?? true,
            file.map(Self.isPlainFileName) ?? true,
            symbol != nil || file != nil
        else { throw CanvasDiagramError.invalidValue }
    }

    /// One path component: no separators, no `..`, no hidden name.
    static func isPlainFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && !name.hasPrefix(".")
            && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}

nonisolated struct CanvasIconPack: Codable, Equatable, Identifiable, Sendable {
    var version = 1
    var id: String
    var name: String
    var vendor: CanvasIconPackVendor
    var entries: [CanvasIconPackEntry]
    var sourceName: String?
    var importedAt: Date?

    init(
        id: String, name: String, vendor: CanvasIconPackVendor, entries: [CanvasIconPackEntry],
        sourceName: String? = nil, importedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.vendor = vendor
        self.entries = entries
        self.sourceName = sourceName
        self.importedAt = importedAt
    }

    func entry(id iconID: String) -> CanvasIconPackEntry? {
        entries.first { $0.id == iconID }
    }

    /// Categories in first-appearance order.
    var categories: [String] {
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }

    func validate() throws {
        guard version == 1, CanvasDiagramText.isIdentifier(id),
            CanvasDiagramText.isValid(name, allowsEmpty: false),
            entries.count <= CanvasDiagramLimits.iconsPerPack,
            Set(entries.map(\.id)).count == entries.count
        else { throw CanvasDiagramError.invalidValue }
        for entry in entries { try entry.validate() }
    }
}

/// One search result.
nonisolated struct CanvasServiceIconMatch: Equatable, Identifiable, Sendable {
    let packID: String
    let packName: String
    let entry: CanvasIconPackEntry
    let score: Int

    var id: String { "\(packID)/\(entry.id)" }
    var iconID: String { entry.id }
    var label: String { entry.name }

    var icon: CanvasServiceIcon {
        CanvasServiceIcon(packID: packID, iconID: entry.id, label: entry.name)
    }
}

nonisolated extension CanvasCardContent {
    /// The frame value of a `.frame` card.
    var diagramFrame: CanvasFrame? {
        if case .frame(let frame) = self { return frame }
        return nil
    }

    /// The icon value of a `.serviceIcon` card.
    var diagramServiceIcon: CanvasServiceIcon? {
        if case .serviceIcon(let icon) = self { return icon }
        return nil
    }
}
