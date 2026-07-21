import Foundation
import Testing

@testable import RafuApp

/// terminal-manager.md T-D: display-name precedence (user name > auto title
/// > generated fallback), inline rename, session color, and the tab-label
/// middle-truncation helper.

// MARK: - displayName precedence

@MainActor
@Test("displayName prefers userName over reportedTitle and the generated fallback")
func displayNamePrefersUserNameOverEverything() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    controller.updateTitle("✳ claude")
    controller.userName = "My Agent"

    #expect(controller.displayName == "My Agent")
}

@MainActor
@Test("displayName falls back to the reported title when there is no user name")
func displayNameFallsBackToReportedTitle() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    controller.updateTitle("✳ claude")

    #expect(controller.displayName == "✳ claude")
}

@MainActor
@Test("displayName falls back to \"<shell> <index>\" with neither a user name nor a reported title")
func displayNameFallsBackToShellAndIndex() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    #expect(controller.displayName == "\(controller.shell.basename) \(controller.index)")
}

@MainActor
@Test("updateTitle(\"\") and a whitespace-only report clear reportedTitle back to the fallback")
func updateTitleWithEmptyOrWhitespaceClearsReportedTitle() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)
    controller.updateTitle("✳ claude")
    #expect(controller.displayName == "✳ claude")

    controller.updateTitle("")
    #expect(controller.displayName == "\(controller.shell.basename) \(controller.index)")

    controller.updateTitle("✳ claude")
    controller.updateTitle("   ")
    #expect(controller.displayName == "\(controller.shell.basename) \(controller.index)")
}

// MARK: - rename

@MainActor
@Test("renameTerminalSession trims and sets userName; empty/nil clears back to auto")
func renameTerminalSessionTrimsAndClears() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    session.renameTerminalSession(controller.id, to: "  My Agent  ")
    #expect(controller.userName == "My Agent")
    #expect(controller.displayName == "My Agent")

    session.renameTerminalSession(controller.id, to: "   ")
    #expect(controller.userName == nil)

    session.renameTerminalSession(controller.id, to: "Another")
    #expect(controller.userName == "Another")
    session.renameTerminalSession(controller.id, to: nil)
    #expect(controller.userName == nil)
}

@MainActor
@Test("renameTerminalSession on an unknown session id is a no-op")
func renameTerminalSessionNoOpsForUnknownID() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    session.renameTerminalSession(UUID(), to: "Should Not Apply")

    #expect(controller.userName == nil)
}

@MainActor
@Test("Rows reflect a rename and hasUserName tracks whether it is user-set")
func rowsReflectRenameAndHasUserName() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    func row() -> TerminalSessionRow {
        let rows = TerminalsPanelModel.rows(
            sessions: session.terminal.sessions,
            presentedIDs: session.presentedTerminalSessionIDs,
            workspaceRoot: session.rootURL?.path
        )
        return rows.first { $0.id == controller.id }!
    }

    #expect(row().hasUserName == false)

    session.renameTerminalSession(controller.id, to: "My Agent")
    #expect(row().displayName == "My Agent")
    #expect(row().hasUserName == true)

    session.renameTerminalSession(controller.id, to: nil)
    #expect(row().hasUserName == false)
}

// MARK: - color

@MainActor
@Test("setTerminalSessionColor round-trips through the controller and the panel rows")
func sessionColorRoundTripsThroughRows() throws {
    let session = WorkspaceSession()
    session.newTerminalTab()
    let controller = try #require(session.terminal.sessions.first)

    session.setTerminalSessionColor(controller.id, .warning)

    #expect(controller.sessionColor == .warning)
    let rows = TerminalsPanelModel.rows(
        sessions: session.terminal.sessions,
        presentedIDs: session.presentedTerminalSessionIDs,
        workspaceRoot: session.rootURL?.path
    )
    #expect(rows.first { $0.id == controller.id }?.sessionColor == .warning)

    session.setTerminalSessionColor(controller.id, nil)
    #expect(controller.sessionColor == nil)
}

@Test("TerminalSessionColor's rawValue round-trips through Codable")
func terminalSessionColorCodableRoundTrips() throws {
    for color in TerminalSessionColor.allCases {
        let encoded = try JSONEncoder().encode(color)
        let decoded = try JSONDecoder().decode(TerminalSessionColor.self, from: encoded)
        #expect(decoded == color)
    }
}

// MARK: - tab label

@Test("tabLabel is identity at/under the limit and middle-truncates over it")
func tabLabelIdentityUnderLimitMiddleTruncatesOver() {
    #expect(TerminalSessionPresentation.tabLabel("short", limit: 20) == "short")
    let exactlyTwenty = String(repeating: "a", count: 20)
    #expect(TerminalSessionPresentation.tabLabel(exactlyTwenty, limit: 20) == exactlyTwenty)

    let long = String(repeating: "a", count: 40)
    let truncated = TerminalSessionPresentation.tabLabel(long, limit: 20)
    #expect(truncated.count == 20)
    #expect(truncated.contains("…"))
    // 19 kept characters split 10 head / 9 tail around the ellipsis.
    #expect(truncated.hasPrefix("aaaaaaaaaa"))
    #expect(truncated.hasSuffix("aaaaaaaaa"))
}

@Test("tabLabel never splits a multibyte/emoji grapheme cluster")
func tabLabelNeverSplitsMultibyteCharacters() {
    let name = String(repeating: "🧑‍💻", count: 25)
    let truncated = TerminalSessionPresentation.tabLabel(name, limit: 20)
    #expect(truncated.count == 20)
    #expect(truncated.contains("…"))
    // Every grapheme cluster in the result is either the ellipsis or a
    // whole, valid emoji — never a lone surrogate/combining scalar.
    for character in truncated where character != "…" {
        #expect(character == "🧑‍💻")
    }
}
