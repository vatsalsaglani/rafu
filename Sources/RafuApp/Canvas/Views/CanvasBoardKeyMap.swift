import SwiftUI

/// The one table of single-letter board keys (no modifiers, lower case,
/// board focused, no card content active). Tools, Add kinds and the extra
/// palette items read their letters from here, and the badges, tooltips,
/// menus and the Ensemble Shortcuts sheet show the same letters.
///
/// These keys stay in the board's local key monitor
/// (`CanvasToolKeyMonitor`) and the board's own `onKeyPress` handlers. They
/// are never menu key equivalents: a menu equivalent with no modifiers runs
/// before a text field sees the key, so typing "r" in a note would pick the
/// Rectangle tool. See `docs/references/canvas-interaction.md`.
///
/// Free for later: B C E J K Q U Y Z.
enum CanvasBoardKeyMap {
    /// The tool letters of the floating tool bar.
    static let toolKeys: [CanvasWhiteboardToolKind: Character] = [
        .select: "v",
        .hand: "h",
        .rectangle: "r",
        .ellipse: "o",
        .diamond: "d",
        .arrow: "a",
        .line: "l",
        .pen: "p",
        .text: "x",
        .mermaid: "m",
        .image: "i",
    ]

    /// The Add letters. Image shares I with the Image tool: both open the
    /// same image chooser.
    static let addKeys: [CanvasAddKind: Character] = [
        .note: "n",
        .terminal: "t",
        .file: "f",
        .image: "i",
        .webApp: "w",
    ]

    static let iconLibraryItemID = "x9.icons"
    static let convertToFrameItemID = "x9.frame"

    /// The letters of the extra palette items, by item id. S opens the icon
    /// library from the tool bar and from the Add palette's Service Icon tile.
    static let paletteItemKeys: [String: Character] = [
        iconLibraryItemID: "s",
        convertToFrameItemID: "g",
    ]

    /// The Add palette's Service Icon… tile opens the same icon library.
    static var serviceIconKey: Character? { paletteItemKeys[iconLibraryItemID] }

    /// The Add kinds whose letter the board view handles itself
    /// (`WorkspaceCanvasView.boardKeys`). The tool monitor lets these keys
    /// pass, so a letter never runs twice.
    static let boardHandledAddKinds: Set<CanvasAddKind> = [.note, .terminal]

    /// One action per letter. Two entries may share a letter only when they
    /// are the same action (Image tool and Add Image…).
    static var bindings: [(key: Character, action: String)] {
        toolKeys.map { ($0.value, actionID(tool: $0.key)) }
            + addKeys.map { ($0.value, actionID(add: $0.key)) }
            + paletteItemKeys.map { ($0.value, "item.\($0.key)") }
    }

    private static func actionID(tool: CanvasWhiteboardToolKind) -> String {
        tool == .image ? "image" : "tool.\(tool.rawValue)"
    }

    private static func actionID(add: CanvasAddKind) -> String {
        add == .image ? "image" : "add.\(add.title)"
    }

    /// Letters bound to two different actions. Empty when the map is sound.
    static func duplicateKeys() -> [Character] {
        var actions: [Character: Set<String>] = [:]
        for binding in bindings { actions[binding.key, default: []].insert(binding.action) }
        return actions.filter { $0.value.count > 1 }.map(\.key).sorted()
    }

    static func assertUnique() {
        assert(duplicateKeys().isEmpty, "Board letters collide: \(duplicateKeys())")
    }

    /// "R" for a badge or a tooltip.
    static func display(_ key: Character) -> String { String(key).uppercased() }

    /// "Rectangle (R)", or the title alone without a key.
    static func helpText(_ title: String, key: Character?) -> String {
        key.map { "\(title) (\(display($0)))" } ?? title
    }

    /// The Add kind a letter adds through the tool monitor, or nil. Note and
    /// Terminal are left to the board view, and Image is the Image tool.
    static func monitorAddKind(for key: Character) -> CanvasAddKind? {
        addKeys.first { kind, letter in
            letter == key && !boardHandledAddKinds.contains(kind) && kind != .image
        }?.key
    }

    /// The palette item id a letter runs, or nil.
    static func paletteItemID(for key: Character) -> String? {
        paletteItemKeys.first { $0.value == key }?.key
    }
}
