import Foundation
import Testing
import UniformTypeIdentifiers

@testable import RafuApp

/// The Terminals panel as a native `List` (direction A, "Quiet list"): the
/// visible row order, stable selection tags, per-window group expansion, the
/// keyboard map, and how the selection follows the current terminal.
@Suite("Terminals panel native list")
struct TerminalsPanelListTests {
    typealias L = TerminalsPanelListModel

    // MARK: Fixtures

    private static func group(
        _ id: TerminalGroupID, name: String = "Build", title: String = "", paneCount: Int = 2,
        isCurrent: Bool = false
    ) -> TerminalsPanelModel.TerminalGroupRow {
        var row = TerminalsPanelModel.TerminalGroupRow(
            id: id, name: name, paneCount: paneCount, livePaneCount: 1, attentionCount: 0,
            isParked: false, isCurrent: isCurrent, isSaved: false, hasRestartablePane: false)
        row.title = title
        return row
    }

    private static func pane(
        _ id: TerminalPaneID, in groupID: TerminalGroupID, name: String = "zsh", ordinal: Int = 1
    ) -> TerminalsPanelModel.TerminalPaneRow {
        var row = TerminalsPanelModel.TerminalPaneRow(
            id: id, groupID: groupID, name: name, detail: "zsh · Live", status: .live,
            hasAttention: false, isFocused: ordinal == 1, isUnavailable: false, sessionID: nil,
            sessionColor: nil, folder: ".", providerOrShell: "zsh", canStart: false,
            canRestart: false)
        row.ordinal = ordinal
        return row
    }

    private static func legacy(_ id: UUID, name: String = "fish") -> TerminalSessionRow {
        TerminalSessionRow(
            id: id, displayName: name, shellName: "fish", directoryLabel: "rafu",
            status: .running, isParked: false, needsAttention: false, hasUserName: false,
            sessionColor: nil)
    }

    /// Two-pane group A, one-pane group B, one legacy session.
    private struct Fixture {
        let groupA = TerminalGroupID()
        let paneA1 = TerminalPaneID()
        let paneA2 = TerminalPaneID()
        let groupB = TerminalGroupID()
        let paneB1 = TerminalPaneID()
        let session = UUID()

        func hierarchy(
            titleA: String = "", currentA: Bool = false, currentLegacy: Bool = false
        ) -> [TerminalsPanelModel.HierarchyRow] {
            [
                .group(TerminalsPanelListTests.group(groupA, title: titleA, isCurrent: currentA)),
                .pane(TerminalsPanelListTests.pane(paneA1, in: groupA, ordinal: 1)),
                .pane(TerminalsPanelListTests.pane(paneA2, in: groupA, ordinal: 2)),
                .group(TerminalsPanelListTests.group(groupB, paneCount: 1)),
                .pane(TerminalsPanelListTests.pane(paneB1, in: groupB)),
                .legacy(TerminalsPanelListTests.legacy(session), isCurrent: currentLegacy),
            ]
        }
    }

    // MARK: Visible rows

    @Test("An expanded group lists its panes under it; a collapsed or one-pane group does not")
    func visibleRowOrder() {
        let f = Fixture()
        let expanded = L.visibleRows(f.hierarchy(), collapsedGroupIDs: [])
        #expect(
            expanded.map(\.id) == [
                L.groupRowID(f.groupA), L.paneRowID(f.paneA1), L.paneRowID(f.paneA2),
                L.groupRowID(f.groupB), L.legacyRowID(f.session),
            ])
        guard case .group(_, let panes, let disclosable, let isExpanded) = expanded[0] else {
            Issue.record("first row is not a group")
            return
        }
        #expect(panes.count == 2 && disclosable && isExpanded)
        guard case .group(_, _, let bDisclosable, let bExpanded) = expanded[3] else {
            Issue.record("fourth row is not a group")
            return
        }
        #expect(!bDisclosable && !bExpanded)

        let collapsed = L.visibleRows(f.hierarchy(), collapsedGroupIDs: [f.groupA])
        #expect(
            collapsed.map(\.id) == [
                L.groupRowID(f.groupA), L.groupRowID(f.groupB), L.legacyRowID(f.session),
            ])
    }

    @Test("Row ids come from identity only, so a rename or a new title keeps them")
    func identityIsStableAcrossTitles() {
        let f = Fixture()
        let before = L.visibleRows(f.hierarchy(titleA: "Build"), collapsedGroupIDs: [])
        let after = L.visibleRows(f.hierarchy(titleA: "Fix flaky tests"), collapsedGroupIDs: [])
        #expect(before.map(\.id) == after.map(\.id))
        #expect(before[0] != after[0])
        let renamedLegacy = TerminalsPanelListModel.Row.legacy(
            Self.legacy(f.session, name: "renamed"), isCurrent: false)
        #expect(renamedLegacy.id == L.legacyRowID(f.session))
        // Tags never collide across kinds, and a saved row is told apart from
        // the Saved header row.
        let saved = SavedTerminalGroupID()
        #expect(L.isSavedLayoutRowID(L.savedRowID(saved)))
        #expect(!L.isSavedLayoutRowID(L.savedHeaderRowID))
        #expect(!L.isSavedLayoutRowID(L.groupRowID(f.groupA)))
        #expect(L.groupRowID(f.groupA).hasSuffix(f.groupA.rawValue.uuidString))
    }

    // MARK: Expansion

    @Test("Collapsed groups persist per window under one key and prune closed groups")
    func expansionPersistence() {
        #expect(L.expansionStorageKey == "terminals.groups.collapsed")
        let a = TerminalGroupID()
        let b = TerminalGroupID()
        let stored = L.storedValue(collapsedGroupIDs: [a, b])
        #expect(L.collapsedGroupIDs(fromStored: stored) == [a, b])
        // Same set, same string.
        #expect(L.storedValue(collapsedGroupIDs: [b, a]) == stored)
        #expect(L.collapsedGroupIDs(fromStored: "") == [])
        #expect(L.collapsedGroupIDs(fromStored: "junk,\(a.rawValue.uuidString)") == [a])

        let closed = TerminalGroupID()
        let collapsedB = L.toggled(b, expand: false, in: [closed], liveGroupIDs: [a, b])
        #expect(collapsedB == [b])
        #expect(L.toggled(b, expand: true, in: collapsedB, liveGroupIDs: [a, b]) == [])
    }

    // MARK: Keyboard

    @Test("Return and Space open; Left and Right close, open, and move like an outline")
    func keyboardMap() {
        let f = Fixture()
        let rows = L.visibleRows(f.hierarchy(), collapsedGroupIDs: [])
        let groupA = L.groupRowID(f.groupA)
        let paneA1 = L.paneRowID(f.paneA1)
        let groupB = L.groupRowID(f.groupB)

        #expect(L.action(for: .returnKey, selection: groupA, rows: rows) == .open(groupA))
        #expect(L.action(for: .space, selection: paneA1, rows: rows) == .open(paneA1))
        #expect(L.action(for: .returnKey, selection: nil, rows: rows) == .none)
        #expect(L.action(for: .returnKey, selection: "group-gone", rows: rows) == .none)
        let saved = L.savedRowID(SavedTerminalGroupID())
        #expect(L.action(for: .returnKey, selection: saved, rows: rows) == .open(saved))

        #expect(L.action(for: .leftArrow, selection: groupA, rows: rows) == .collapse(f.groupA))
        #expect(L.action(for: .rightArrow, selection: groupA, rows: rows) == .select(paneA1))
        #expect(L.action(for: .leftArrow, selection: paneA1, rows: rows) == .select(groupA))
        #expect(L.action(for: .rightArrow, selection: paneA1, rows: rows) == .none)
        // A one-pane group has no disclosure.
        #expect(L.action(for: .leftArrow, selection: groupB, rows: rows) == .none)
        #expect(L.action(for: .rightArrow, selection: groupB, rows: rows) == .none)

        let collapsed = L.visibleRows(f.hierarchy(), collapsedGroupIDs: [f.groupA])
        #expect(
            L.action(for: .rightArrow, selection: groupA, rows: collapsed) == .expand(f.groupA))
        #expect(L.action(for: .leftArrow, selection: groupA, rows: collapsed) == .none)

        let header = L.savedHeaderRowID
        #expect(
            L.action(for: .returnKey, selection: header, rows: rows, isSavedExpanded: false)
                == .setSavedExpanded(true))
        #expect(
            L.action(for: .space, selection: header, rows: rows, isSavedExpanded: true)
                == .setSavedExpanded(false))
        #expect(
            L.action(for: .leftArrow, selection: header, rows: rows, isSavedExpanded: true)
                == .setSavedExpanded(false))
        #expect(
            L.action(for: .rightArrow, selection: header, rows: rows, isSavedExpanded: true)
                == .none)
    }

    // MARK: Selection

    @Test("The selection follows the current terminal but keeps a pane of the current group")
    func selectionFollowsCurrent() {
        let f = Fixture()
        let rows = L.visibleRows(f.hierarchy(currentA: true), collapsedGroupIDs: [])
        let current = L.currentRowID(rows)
        #expect(current == L.groupRowID(f.groupA))
        #expect(
            L.selectionFollowingCurrent(current, selection: nil, rows: rows)
                == L.groupRowID(f.groupA))
        #expect(
            L.selectionFollowingCurrent(current, selection: L.paneRowID(f.paneA2), rows: rows)
                == L.paneRowID(f.paneA2))
        #expect(
            L.selectionFollowingCurrent(current, selection: L.groupRowID(f.groupB), rows: rows)
                == L.groupRowID(f.groupA))
        // No current terminal: the selection stays where the user put it.
        #expect(
            L.selectionFollowingCurrent(nil, selection: L.groupRowID(f.groupB), rows: rows)
                == L.groupRowID(f.groupB))

        let legacyRows = L.visibleRows(f.hierarchy(currentLegacy: true), collapsedGroupIDs: [])
        #expect(L.currentRowID(legacyRows) == L.legacyRowID(f.session))
    }

    @Test("Collapsing a group moves a selected pane of it to the group row")
    func selectionAfterCollapse() {
        let f = Fixture()
        let panes = [f.paneA1, f.paneA2]
        #expect(
            L.selectionAfterCollapsing(f.groupA, paneIDs: panes, selection: L.paneRowID(f.paneA2))
                == L.groupRowID(f.groupA))
        #expect(
            L.selectionAfterCollapsing(f.groupA, paneIDs: panes, selection: L.paneRowID(f.paneB1))
                == L.paneRowID(f.paneB1))
        #expect(L.selectionAfterCollapsing(f.groupA, paneIDs: panes, selection: nil) == nil)
    }

    // MARK: Saved footer

    @Test("The footer list is sized to its fixed-height rows")
    func savedFooterHeight() {
        typealias S = TerminalGroupSavedLayoutsPresentation
        let row = S.rowHeight
        #expect(S.footerHeight(state: .empty, isExpanded: false, recordCount: 0) == row)
        #expect(S.footerHeight(state: .empty, isExpanded: true, recordCount: 0) == row * 2)
        #expect(S.footerHeight(state: .records, isExpanded: true, recordCount: 3) == row * 4)
        #expect(
            S.footerHeight(state: .records, isExpanded: true, recordCount: 40)
                == row * CGFloat(1 + S.maximumFooterRecordRows))
    }

    // MARK: Source contracts

    @Test("The panel is a native List with a single selection, keyboard map, and hidden background")
    func listSourceContract() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        #expect(panel.contains("List(selection: $listSelection)"))
        #expect(panel.contains("@State private var listSelection: String?"))
        #expect(panel.contains(".tag(row.id)"))
        #expect(panel.contains("listStyle(.plain)"))
        #expect(panel.contains(".scrollContentBackground(.hidden)"))
        #expect(panel.contains(".tint(theme.palette.selection)"))
        #expect(panel.contains(".onKeyPress(keys: [.return, .space, .leftArrow, .rightArrow])"))
        #expect(panel.contains("TerminalsPanelListModel.action("))
        #expect(panel.contains(".onChange(of: currentRowID, initial: true)"))
        #expect(!panel.contains("ScrollView {"))
        // Rows are list rows: no per-row Tab stop, and no `Button` label that
        // would take the press from `.onDrag` or delay a click.
        #expect(!panel.contains(".focusable()"))
        #expect(!panel.contains(".onTapGesture(count: 2)"))
        #expect(!panel.contains(".buttonStyle(.plain)\n                .focused("))
        // A group disclosure is not a system `DisclosureGroup`, so the list
        // never becomes an `NSOutlineView`.
        #expect(!panel.contains("DisclosureGroup("))
        #expect(!panel.contains("OutlineGroup("))
        // VoiceOver: the disclosure state is spoken and has an action.
        #expect(panel.contains(#"values.append(isExpanded ? "Expanded" : "Collapsed")"#))
        #expect(panel.contains(#"Button(isExpanded ? "Collapse" : "Expand")"#))

        let saved = try Self.source("Sources/RafuApp/Views/TerminalGroupSavedLayoutsSection.swift")
        #expect(saved.contains(".tag(TerminalsPanelListModel.savedHeaderRowID)"))
        #expect(saved.contains(".tag(rowID)"))
        #expect(saved.contains(".selectionDisabled()"))
        #expect(!saved.contains("ScrollView {"))
    }

    @Test("The group row is still the Ensemble drag source and the payload names only the group")
    func dragPayloadStillProduced() throws {
        let panel = try Self.source("Sources/RafuApp/Views/WorkspaceTerminalsPanelView.swift")
        let start = try #require(panel.range(of: "private struct TerminalGroupManagerRowView"))
        let end = try #require(
            panel.range(
                of: "private struct TerminalPaneMenuItems", range: start.upperBound..<panel.endIndex
            ))
        let row = String(panel[start.upperBound..<end.lowerBound])
        #expect(row.contains(".onDrag("))
        #expect(row.contains("CanvasBoardDragPayload(terminalGroupID: row.id).makeItemProvider()"))

        let groupID = TerminalGroupID()
        let provider = CanvasBoardDragPayload(terminalGroupID: groupID).makeItemProvider()
        #expect(provider.registeredTypeIdentifiers == [UTType.rafuEnsembleDrag.identifier])
    }

    private enum LookupError: Error { case repositoryRootNotFound }

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
        throw LookupError.repositoryRootNotFound
    }
}
