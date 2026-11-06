import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// The one table of single-letter board keys (`CanvasBoardKeyMap`), the tool
/// key monitor's filter, and the source rules that keep those letters out of
/// menu key equivalents.
@Suite("Ensemble board key map")
@MainActor
struct CanvasBoardKeyMapTests {
    @Test("Every board letter names one action across tools, Add kinds and palette items")
    func lettersAreUnique() {
        #expect(CanvasBoardKeyMap.duplicateKeys().isEmpty)
        // Every tool and every Add kind has a letter.
        for kind in CanvasWhiteboardToolKind.allCases {
            #expect(CanvasBoardKeyMap.toolKeys[kind] != nil, "\(kind)")
        }
        for kind in CanvasAddKind.allCases {
            #expect(kind.key != nil, "\(kind)")
        }
    }

    @Test("The agreed letters")
    func agreedLetters() {
        let tools = CanvasWhiteboardToolKind.allCases.map { String($0.key) }.joined()
        #expect(tools == "vhrodalpxmi")
        #expect(CanvasAddKind.note.key == "n")
        #expect(CanvasAddKind.terminal.key == "t")
        #expect(CanvasAddKind.file.key == "f")
        #expect(CanvasAddKind.image.key == "i")
        #expect(CanvasAddKind.webApp.key == "w")
        #expect(CanvasBoardKeyMap.serviceIconKey == "s")
        #expect(CanvasBoardKeyMap.paletteItemKeys[CanvasBoardKeyMap.convertToFrameItemID] == "g")
    }

    @Test("A duplicate letter is reported")
    func duplicateDetection() {
        // Image tool and Add Image share I on purpose: same action.
        #expect(!CanvasBoardKeyMap.duplicateKeys().contains("i"))
        #expect(CanvasBoardKeyMap.toolKeys[.image] == CanvasBoardKeyMap.addKeys[.image])
    }

    @Test("The monitor leaves N and T to the board view and adds File and Web App itself")
    func monitorAddKinds() {
        #expect(CanvasBoardKeyMap.monitorAddKind(for: "n") == nil)
        #expect(CanvasBoardKeyMap.monitorAddKind(for: "t") == nil)
        #expect(CanvasBoardKeyMap.monitorAddKind(for: "i") == nil)
        #expect(CanvasBoardKeyMap.monitorAddKind(for: "f") == .file)
        #expect(CanvasBoardKeyMap.monitorAddKind(for: "w") == .webApp)
        #expect(CanvasBoardKeyMap.paletteItemID(for: "s") == CanvasBoardKeyMap.iconLibraryItemID)
        #expect(CanvasBoardKeyMap.paletteItemID(for: "q") == nil)
    }

    @Test("Tooltips name the letter")
    func helpText() {
        #expect(CanvasWhiteboardToolKind.rectangle.helpText == "Rectangle (R)")
        #expect(CanvasBoardKeyMap.helpText("Add Note", key: "n") == "Add Note (N)")
        #expect(CanvasBoardKeyMap.helpText("Style", key: nil) == "Style")
        #expect(
            CanvasAddPopover.helpText(of: .item(.kind(.note)), title: "Note") == "Add Note (N)")
        #expect(CanvasAddPopover.key(of: .serviceIcon) == "s")
    }

    @Test("Only a plain, lower-case, non-repeating letter or Escape is a tool key")
    func keyFilter() throws {
        func event(
            _ characters: String, flags: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
            keyCode: UInt16 = 15
        ) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: 0, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: isRepeat,
                    keyCode: keyCode))
        }
        #expect(CanvasToolKeyMonitor.key(for: try event("r")) == .character("r"))
        #expect(CanvasToolKeyMonitor.key(for: try event("R")) == nil)
        #expect(CanvasToolKeyMonitor.key(for: try event("R", flags: .shift)) == nil)
        #expect(CanvasToolKeyMonitor.key(for: try event("r", flags: .command)) == nil)
        #expect(CanvasToolKeyMonitor.key(for: try event("r", flags: .option)) == nil)
        #expect(CanvasToolKeyMonitor.key(for: try event("r", isRepeat: true)) == nil)
        #expect(CanvasToolKeyMonitor.key(for: try event("1", keyCode: 18)) == nil)
        #expect(CanvasToolKeyMonitor.key(for: try event("\u{1B}", keyCode: 53)) == .escape)
    }

    @Test("Text input keeps its letters: field editors and text views block board keys")
    func textInputBlocksBoardKeys() {
        #expect(CanvasToolKeyMonitor.responderAllowsBoardKeys(nil))
        #expect(CanvasToolKeyMonitor.responderAllowsBoardKeys(NSView()))
        #expect(!CanvasToolKeyMonitor.responderAllowsBoardKeys(NSTextView()))
    }

    @Test("No modifier-free key equivalent in the app: board letters stay in the key monitor")
    func noPlainLetterMenuEquivalents() throws {
        for file in try Self.swiftFiles(under: "Sources/RafuApp") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let letter = source.firstMatch(
                of: #/keyboardShortcut\("[a-zA-Z]", modifiers: \[\]\)/#)
            #expect(letter == nil, Comment(rawValue: file.lastPathComponent))
        }
    }

    @Test("Ensemble popups use the Rafu popup language, not NSAlert")
    func noAlertsInEnsemble() throws {
        // The Ensemble file error uses `RafuPopupPresenter` (ADR 0033
        // amendment); the one no-window `NSAlert` fallback lives there.
        let allowed: [String: Int] = [:]
        for file in try Self.swiftFiles(under: "Sources/RafuApp/Canvas") {
            let source = try String(contentsOf: file, encoding: .utf8)
            let count = source.components(separatedBy: "NSAlert(").count - 1
            #expect(
                count == allowed[file.lastPathComponent, default: 0],
                Comment(rawValue: file.lastPathComponent))
        }
        let dialogs = try Self.source("Sources/RafuApp/Canvas/Views/CanvasDialogView.swift")
        #expect(!dialogs.contains("Image(systemName: \"minus\")"))
        #expect(!dialogs.contains("List(items, selection:"))
        let presentations = try Self.source(
            "Sources/RafuApp/Canvas/Views/CanvasPresentations.swift")
        #expect(!presentations.contains(".confirmationDialog("))
    }

    @Test("The Style menu has a visible symbol label")
    func styleMenuLabel() throws {
        let palette = try Self.source("Sources/RafuApp/Canvas/Whiteboard/CanvasToolPalette.swift")
        let start = try #require(palette.range(of: "struct CanvasWhiteboardStyleMenu: View"))
        let style = palette[start.upperBound...]
        #expect(style.contains("Image(systemName: \"paintpalette\")"))
        #expect(style.contains(".help(\"Style\")"))
    }

    static func swiftFiles(under path: String) throws -> [URL] {
        let root = try packageRoot().appending(path: path)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
    }

    static func source(_ path: String) throws -> String {
        try String(contentsOf: packageRoot().appending(path: path), encoding: .utf8)
    }

    static func packageRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
