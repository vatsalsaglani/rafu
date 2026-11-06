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
}
