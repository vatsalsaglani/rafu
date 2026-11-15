import Foundation
import Testing

@testable import RafuApp

/// Every dialog uses the Rafu popup language (ADR 0033, amendment of
/// 2026-11-06). These source policies keep system alerts and confirmation
/// dialogs out of `Sources/RafuApp`.
@Suite("Rafu dialog policy")
@MainActor
struct RafuDialogPolicyTests {
    /// The system alert API appears only in the no-window fallback.
    private static let allowedCounts: [String: [String: Int]] = [
        "RafuPopupPresenter.swift": ["NSAlert(": 1, "alert.runModal()": 1]
    ]
    private static let forbidden = [
        ".alert(", ".confirmationDialog(", "NSAlert(", "alert.runModal()",
    ]

    @Test("No system alert or confirmation dialog outside the presenter fallback")
    func noSystemAlerts() throws {
        for file in try CanvasBoardKeyMapTests.swiftFiles(under: "Sources/RafuApp") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbidden {
                let count = source.components(separatedBy: token).count - 1
                let allowed = Self.allowedCounts[file.lastPathComponent]?[token] ?? 0
                #expect(
                    count == allowed, Comment(rawValue: "\(file.lastPathComponent): \(token)"))
            }
        }
    }

    @Test("Navigation Peek, Rename File and the window popups use the popup components")
    func migratedSurfaces() throws {
        let peek = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Views/NavigationPeekView.swift")
        #expect(peek.contains("RafuPopupHeader("))
        #expect(peek.contains("RafuPopupRow("))
        #expect(!peek.contains("strokeBorder(theme.palette.borderStrong.opacity(0.5))"))
        let sidebar = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        #expect(sidebar.contains("RafuTextFieldPopup("))
        #expect(sidebar.contains("RafuConfirmPopup("))
        let window = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Views/WorkspaceWindowView.swift")
        #expect(window.contains("RafuMessagePopup("))
        #expect(window.contains("RafuPopupFooter("))
        let editor = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Views/EditorCanvasView.swift")
        #expect(editor.contains("defaultActionID: \"Save and Close\""))
    }

    @Test("The Canvas text popup is the shared Rafu text popup")
    func sharedTextPopup() throws {
        let menus = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Canvas/Diagram/CanvasDiagramMenus.swift")
        #expect(!menus.contains("CanvasTextFieldPopup"))
        #expect(menus.contains("RafuTextFieldPopup("))
    }

    /// `FileHandle.write(_:)` raises an Objective-C exception when stderr is
    /// closed (the terminal is gone), and the helper aborts. Crash report
    /// rafu-2026-11-15-190621: `CanvasCodexSession.run` closure, exit line.
    @Test("Helper processes write stderr with the throwing API only")
    func stderrWritesCannotAbort() throws {
        for path in [
            "Sources/RafuCore/CanvasBridge/CanvasCodexSession.swift",
            "Sources/RafuCore/CanvasBridge/CanvasBridgeLaunch.swift",
            "Sources/RafuCore/CanvasBridge/CanvasBridgeMCPServer.swift",
            "Sources/RafuCLI/main.swift",
        ] {
            // The formatter can wrap `contentsOf:` onto its own line.
            let text = try CanvasBoardKeyMapTests.source(path)
                .filter { !$0.isWhitespace }
            let raising =
                text.components(separatedBy: "standardError.write(").count
                - text.components(separatedBy: "standardError.write(contentsOf:").count
            #expect(raising == 0, "\(path) uses the raising FileHandle.write(_:)")
        }
    }

    @Test("Import Pack closes the floating Icon Library before its sheet opens")
    func importClosesTheLibraryFirst() throws {
        let menus = try CanvasBoardKeyMapTests.source(
            "Sources/RafuApp/Canvas/Diagram/CanvasDiagramMenus.swift")
        let body = try #require(
            menus.range(of: "static func showImport()").map { String(menus[$0.upperBound...]) })
        let close = try #require(body.range(of: "libraryHolder.panel?.close()"))
        let sheet = try #require(body.range(of: "presentSheet("))
        #expect(close.lowerBound < sheet.lowerBound)
    }
}
