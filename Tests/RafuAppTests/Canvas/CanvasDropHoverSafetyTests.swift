import Foundation
import Testing

@testable import RafuApp

/// Regression for the "no tab is clickable after a drag" wedge. A Rafu
/// private drag (both private types conform to `public.data`) is written by
/// SwiftUI's `.onDrag` with a file promise. `DropInfo.itemProviders(for:)`
/// called while the drag only hovers makes `NSFilePromiseReceiver` raise
/// `NSInternalInconsistencyException`; AppKit catches it and cancels the
/// drag, and the unwind leaves the window's SwiftUI input dead. Hover code
/// must read type presence only; providers are decoded at `performDrop`.
/// See `docs/references/swiftui-drop-hover-file-promise.md`.
@Suite("Drop hover never decodes item providers")
struct CanvasDropHoverSafetyTests {
    @Test("The board's hover kind keeps the ensemble > editor > file priority")
    func hoverKindPriority() {
        typealias Kind = CanvasBoardDropHoverKind
        #expect(
            Kind.resolve(hasEnsembleDrag: true, hasEditorDrag: true, hasFileURL: true) == .ensemble)
        #expect(
            Kind.resolve(hasEnsembleDrag: true, hasEditorDrag: false, hasFileURL: false)
                == .ensemble)
        #expect(
            Kind.resolve(hasEnsembleDrag: false, hasEditorDrag: true, hasFileURL: true) == .editor)
        #expect(
            Kind.resolve(hasEnsembleDrag: false, hasEditorDrag: false, hasFileURL: true) == .files)
        #expect(
            Kind.resolve(hasEnsembleDrag: false, hasEditorDrag: false, hasFileURL: false) == .none)
    }

    @Test("Every DropInfo.itemProviders(for:) call sits in a perform function")
    func providersOnlyAtPerform() throws {
        let root = try Self.packageRoot()
        let sources = root.appending(path: "Sources/RafuApp")
        let files = try #require(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        var violations: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("itemProviders(for:") else { continue }
            for hit in Self.providerCalls(in: text) {
                checked += 1
                if !hit.function.hasPrefix("perform") {
                    violations.append("\(url.lastPathComponent):\(hit.line) in \(hit.function)")
                }
            }
        }
        // Non-vacuous: the board and editor delegates do decode at perform.
        #expect(checked >= 4)
        #expect(violations.isEmpty, "itemProviders(for:) outside perform: \(violations)")
    }

    @Test("The board delegate's hover path reads type presence only")
    func boardHoverUsesTypePresence() throws {
        let source = try String(
            contentsOf: try Self.packageRoot().appending(
                path: "Sources/RafuApp/Canvas/Views/CanvasFileDropDelegate.swift"),
            encoding: .utf8)
        #expect(source.contains("info.hasItemsConforming(to: [.rafuEnsembleDrag])"))
        #expect(source.contains("info.hasItemsConforming(to: [.rafuEditorDrag])"))
        #expect(source.contains("info.hasItemsConforming(to: [.fileURL])"))
        // The temporary drag diagnostics must not decode either.
        #expect(!source.contains("ensemble=\\(!info.itemProviders"))
    }

    /// Each non-comment `itemProviders(for:` call with the name of the
    /// nearest `func` declared above it (closures declare none, so this is
    /// the enclosing named function).
    private static func providerCalls(in text: String) -> [(line: Int, function: String)] {
        var function = "<file scope>"
        var hits: [(line: Int, function: String)] = []
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
        {
            let line = rawLine.drop { $0 == " " || $0 == "\t" }
            if line.hasPrefix("//") { continue }
            if let range = line.range(of: "func ") {
                let name = line[range.upperBound...].prefix {
                    $0.isLetter || $0.isNumber || $0 == "_"
                }
                if !name.isEmpty { function = String(name) }
            }
            if line.contains("itemProviders(for:") {
                hits.append((index + 1, function))
            }
        }
        return hits
    }

    private static func packageRoot(file: StaticString = #filePath) throws -> URL {
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
