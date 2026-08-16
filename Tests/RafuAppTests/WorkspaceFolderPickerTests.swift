import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Workspace folder picker")
struct WorkspaceFolderPickerTests {
    @MainActor
    @Test("The workspace picker accepts one directory and no files")
    func panelConfiguration() {
        let panel = WorkspaceFolderPicker.makePanel()

        #expect(panel.canChooseDirectories)
        #expect(!panel.canChooseFiles)
        #expect(!panel.allowsMultipleSelection)
        #expect(panel.canCreateDirectories)
        #expect(panel.prompt == "Open")
    }

    @Test("One SwiftUI file importer owns the window presentation chain")
    func windowHasOneFileImporterOwner() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")

        #expect(source.components(separatedBy: ".fileImporter(").count - 1 == 1)
        #expect(source.contains("isPresented: terminalPaneStartingFolderBinding"))
        #expect(!source.contains("$session.isOpenFolderImporterPresented"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw WorkspaceFolderPickerTestError.repositoryRootNotFound
    }

    private enum WorkspaceFolderPickerTestError: Error {
        case repositoryRootNotFound
    }
}
