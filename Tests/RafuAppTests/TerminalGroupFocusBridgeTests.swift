import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal Group focus bridge")
struct TerminalGroupFocusBridgeTests {
    @Test("Only the focused pane requests first responder")
    func sourceGatesResponderRequestsToFocusedPane() throws {
        let source = try Self.source("Sources/RafuApp/Terminal/EditorTerminalTabContent.swift")

        #expect(source.contains("TerminalHostView(controller: controller, theme: theme)"))
        #expect(
            source.contains("guard coordinator.allowsFocusRequest(isFocusedPane) else { return }"))
        #expect(source.contains("guard isFocusedPane else {"))
        #expect(source.contains("invalidatePendingFocusRequest()"))
        #expect(source.contains("requestFocusToken"))
        #expect(source.contains("onDidBecomeFirstResponder"))
        #expect(source.contains("static func dismantleNSView"))
        #expect(source.contains("focusRequestGeneration"))
        #expect(source.contains("clearFirstResponderCallback(owner: coordinator)"))
    }

    @MainActor
    @Test("An unfocused update invalidates a queued first-responder request")
    func unfocusedUpdateInvalidatesQueuedFocus() {
        let coordinator = TerminalHostView.Coordinator()
        coordinator.lastRequestedFocusToken = 12
        coordinator.focusRequestGeneration = 4

        #expect(!coordinator.allowsFocusRequest(false))
        #expect(coordinator.lastRequestedFocusToken == nil)
        #expect(coordinator.focusRequestGeneration == 5)
    }

    @MainActor
    @Test("A stale terminal host cannot clear a newer focus callback owner")
    func callbackOwnerReplacementIsSafe() {
        let terminalView = RafuTerminalView(frame: .zero)
        let staleOwner = NSObject()
        let currentOwner = NSObject()
        var staleCalls = 0
        var currentCalls = 0

        terminalView.setFirstResponderCallback(owner: staleOwner) { staleCalls += 1 }
        terminalView.setFirstResponderCallback(owner: currentOwner) { currentCalls += 1 }
        terminalView.clearFirstResponderCallback(owner: staleOwner)
        terminalView.onDidBecomeFirstResponder?()

        #expect(staleCalls == 0)
        #expect(currentCalls == 1)
        terminalView.clearFirstResponderCallback(owner: currentOwner)
        #expect(terminalView.onDidBecomeFirstResponder == nil)
    }

    @Test("Pointer responder callbacks preserve the terminal pane identity")
    func sourceForwardsThePaneIdentity() throws {
        let source = try Self.source("Sources/RafuApp/Terminal/EditorTerminalTabContent.swift")
        let terminalView = try Self.source("Sources/RafuApp/Terminal/RafuTerminalView.swift")

        #expect(source.contains("guard let paneID = coordinator?.paneID"))
        #expect(source.contains("coordinator?.onDidBecomeFirstResponder?(paneID)"))
        #expect(terminalView.contains("override func mouseDown(with event: NSEvent)"))
        #expect(
            terminalView.contains(
                "guard let window, window.firstResponder !== self else { return }"))
        #expect(terminalView.contains("guard window.makeFirstResponder(self) else { return }"))
        #expect(terminalView.contains("onDidBecomeFirstResponder?()"))
        #expect(terminalView.contains("onDidBecomeFirstResponder?()"))
        #expect(terminalView.contains("firstResponderCallbackOwner === owner"))
    }

    @Test("Pane presentation keeps fixed unavailable messages and attention text")
    func fixedPanePresentationStates() {
        #expect(
            TerminalPanePresentation.unavailableMessage(for: .unavailableAgentTerminal)
                == "Agent Terminal profiles are not saved in this version."
        )
        #expect(
            TerminalPanePresentation.unavailableMessage(for: .unavailableEnsemble)
                == "Ensemble terminal profiles are not saved in this version."
        )
        #expect(
            TerminalPanePresentation.statusLabel(
                for: Self.terminalPane(status: .live),
                controllerStatus: .bell
            ) == "Attention"
        )
    }

    private static func terminalPane(status: TerminalPaneStatus) -> TerminalPaneSnapshot {
        try! TerminalPaneSnapshot(
            id: TerminalPaneID(),
            sessionID: UUID(),
            explicitUserName: nil,
            reportedTitle: nil,
            runtimeKind: .ordinaryShell,
            themeColor: nil,
            status: status,
            launchProfile: nil,
            startAvailability: .notRestartable
        )
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw TerminalGroupFocusBridgeTestError.repositoryRootNotFound
    }

    private enum TerminalGroupFocusBridgeTestError: Error {
        case repositoryRootNotFound
    }
}
