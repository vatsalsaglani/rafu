import Foundation
import Testing

@testable import RafuApp

/// macOS redesign W1: workbench chrome, tabs, find, search, palette, status
/// bar and Resources. Everything here is pure logic or a source-level contract;
/// no view is instantiated.
@Suite("Workbench chrome redesign")
struct WorkbenchChromeRedesignTests {
    @Test("Status bar has an accessible session-only initializer")
    @MainActor
    func statusBarInitializerPreservesSession() {
        let session = WorkspaceSession()
        let view = WorkspaceStatusBar(session: session)
        #expect(view.session === session)
    }

    // MARK: - E1: editor group border

    @Test("A document group has a neutral frame and no gold, focused or not")
    func documentGroupBorderIsNeutral() {
        for isFocused in [false, true] {
            let resolution = TerminalSurfaceBorderStyle.resolve(
                context: .editorGroup(isFocused: isFocused),
                identity: .none,
                contrast: .normal
            )
            #expect(resolution.neutralStructure == .borderSubtle)
            #expect(resolution.emphasis == .none)
            #expect(resolution.emphasisWidth == 0)
            #expect(resolution.emphasisRole != .focusRing)
        }
    }

    @Test("Focus on a document group is shown only when siblings exist, and never in gold")
    func siblingFocusIsSubtle() {
        let alone = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true, hasSiblings: false),
            identity: .none, contrast: .normal)
        #expect(alone.emphasis == .none)

        let focusedAmongSiblings = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true, hasSiblings: true),
            identity: .none, contrast: .normal)
        #expect(focusedAmongSiblings.emphasis == .editorFocus)
        #expect(focusedAmongSiblings.emphasisRole == .borderStrong)
        #expect(focusedAmongSiblings.emphasisWidth == 1)

        let unfocusedAmongSiblings = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false, hasSiblings: true),
            identity: .none, contrast: .normal)
        #expect(unfocusedAmongSiblings.emphasis == .none)
    }

    @Test("A focused terminal group keeps the gold focus ring and its session colour")
    func focusedTerminalKeepsGold() {
        let plain = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true, hostsTerminal: true),
            identity: .none, contrast: .normal)
        #expect(plain.emphasisRole == .focusRing)
        #expect(plain.emphasisWidth == 2)

        let colored = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true, hostsTerminal: true, hasSiblings: true),
            identity: .assigned(matchesEditorBackground: false), contrast: .normal)
        #expect(colored.emphasisRole == .focusRing)
        #expect(colored.showsIdentityAccent)
        #expect(colored.identityAndEmphasisDoNotOverlap)

        let unfocused = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false, hostsTerminal: true),
            identity: .assigned(matchesEditorBackground: false), contrast: .normal)
        #expect(unfocused.emphasis == .none)
        #expect(unfocused.showsIdentityAccent)
    }

    @Test("Increase Contrast promotes the neutral frame, still without gold")
    func increasedContrastStaysNeutral() {
        let resolution = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true),
            identity: .none, contrast: .increased)
        #expect(resolution.neutralStructure == .borderStrong)
        #expect(resolution.emphasisRole != .focusRing)
    }

    // MARK: - E4: tab trailing slot

    @Test("Tab slot: close on the selected tab and on hover, dot for dirty at rest")
    func tabAccessoryResolution() {
        #expect(
            EditorTabAccessory.resolve(isSelected: false, isHovering: false, isDirty: false)
                == .hidden)
        #expect(
            EditorTabAccessory.resolve(isSelected: true, isHovering: false, isDirty: false)
                == .close)
        #expect(
            EditorTabAccessory.resolve(isSelected: false, isHovering: true, isDirty: false)
                == .close)
        #expect(
            EditorTabAccessory.resolve(isSelected: false, isHovering: false, isDirty: true)
                == .dirtyDot)
        #expect(
            EditorTabAccessory.resolve(isSelected: true, isHovering: false, isDirty: true)
                == .dirtyDot)
        // The dot turns into the close mark on hover.
        #expect(
            EditorTabAccessory.resolve(isSelected: true, isHovering: true, isDirty: true) == .close)
        #expect(
            EditorTabAccessory.resolve(isSelected: false, isHovering: true, isDirty: true) == .close
        )
    }

    // MARK: - Window redesign phase 4b: activity dot

    @Test("Hover always wins; an activity dot outranks a plain dirty dot")
    func tabAccessoryActivityPrecedence() {
        // Hover wins even with an active agent status.
        #expect(
            EditorTabAccessory.resolve(
                isSelected: false, isHovering: true, isDirty: false, activity: .working) == .close
        )
        // Activity, absent hover, wins over the resting selected/hidden
        // fallback and over a (never co-occurring in practice) dirty flag.
        #expect(
            EditorTabAccessory.resolve(
                isSelected: false, isHovering: false, isDirty: true, activity: .needsYou)
                == .activityDot(.needsYou))
        #expect(
            EditorTabAccessory.resolve(
                isSelected: true, isHovering: false, isDirty: false, activity: .failed)
                == .activityDot(.failed))
        // No activity at all falls back to today's dirty/selected/hidden
        // resolution unchanged.
        #expect(
            EditorTabAccessory.resolve(isSelected: false, isHovering: false, isDirty: false)
                == .hidden)
    }

    @Test("Only working, needsYou, failed, and doneUnread read as activity")
    func activityKindMapping() {
        #expect(EditorTabActivityKind.from(.working) == .working)
        #expect(EditorTabActivityKind.from(.needsYou(.approval)) == .needsYou)
        #expect(EditorTabActivityKind.from(.needsYou(.input)) == .needsYou)
        #expect(EditorTabActivityKind.from(.failed) == .failed)
        #expect(EditorTabActivityKind.from(.doneUnread) == .doneUnread)
        #expect(EditorTabActivityKind.from(.done) == nil)
        #expect(EditorTabActivityKind.from(.inactive) == nil)
        #expect(EditorTabActivityKind.from(.stopped) == nil)
        #expect(EditorTabActivityKind.from(nil) == nil)
    }

    @Test("The hover preview content builders never fabricate an elapsed time or a thumbnail")
    func hoverPreviewContentBuilders() {
        let file = TabHoverPreviewContentBuilder.file(
            title: "Session.swift", workspaceRelativePath: "Sources/RafuApp/Session.swift")
        #expect(file.title == "Session.swift")
        #expect(file.statusWord == nil)
        #expect(file.subtitle == "Sources/RafuApp/Session.swift")
        #expect(file.elapsedLabel == nil)

        let workingTerminal = TabHoverPreviewContentBuilder.terminal(
            title: "zsh", shellOrAgentName: "zsh", status: .working, elapsedLabel: "4m")
        #expect(workingTerminal.statusWord == "Working")
        #expect(workingTerminal.elapsedLabel == "4m")

        // No matched session: no status word, and never an elapsed label
        // even if one happened to be supplied.
        let plainShell = TabHoverPreviewContentBuilder.terminal(
            title: "zsh", shellOrAgentName: "zsh", status: nil, elapsedLabel: "4m")
        #expect(plainShell.statusWord == nil)
        #expect(plainShell.elapsedLabel == nil)

        let quietEnsemble = TabHoverPreviewContentBuilder.ensemble(
            title: "Ensemble", hasCardNeedingApproval: false)
        #expect(quietEnsemble.statusWord == nil)
        #expect(quietEnsemble.subtitle == "Ensemble")

        let waitingEnsemble = TabHoverPreviewContentBuilder.ensemble(
            title: "Ensemble", hasCardNeedingApproval: true)
        #expect(waitingEnsemble.statusWord == "Needs approval")
    }

    // MARK: - E5: find in selection

    @Test("Find in Selection keeps only matches fully inside the scope")
    func selectionScopeFilter() {
        let matches = [
            TextSearchMatch(range: NSRange(location: 0, length: 3), replacement: ""),
            TextSearchMatch(range: NSRange(location: 10, length: 3), replacement: ""),
            TextSearchMatch(range: NSRange(location: 18, length: 4), replacement: ""),
            TextSearchMatch(range: NSRange(location: 30, length: 3), replacement: ""),
        ]
        let scope = NSRange(location: 10, length: 10)  // 10..<20
        let filtered = FindSelectionScope.filter(matches, within: scope)
        #expect(filtered.map(\.range.location) == [10])  // 18..<22 straddles the end
        #expect(FindSelectionScope.filter(matches, within: nil).count == 4)
        let wide = FindSelectionScope.filter(matches, within: NSRange(location: 10, length: 13))
        #expect(wide.map(\.range.location) == [10, 18])
    }

    @Test("The selection scope follows edits before, after, and inside it")
    func selectionScopeAdjustment() {
        let scope = NSRange(location: 10, length: 10)
        // Insert 4 characters at offset 2 (before the scope).
        let before = FindSelectionScope.adjusted(
            scope, editedRange: NSRange(location: 2, length: 4), changeInLength: 4)
        #expect(before == NSRange(location: 14, length: 10))
        // Delete 3 characters at offset 30 (after the scope).
        let after = FindSelectionScope.adjusted(
            scope, editedRange: NSRange(location: 30, length: 0), changeInLength: -3)
        #expect(after == scope)
        // Replace 3 characters inside the scope with 5 (net +2).
        let inside = FindSelectionScope.adjusted(
            scope, editedRange: NSRange(location: 12, length: 5), changeInLength: 2)
        #expect(inside == NSRange(location: 10, length: 12))
        // Shrinking never goes negative.
        let collapse = FindSelectionScope.adjusted(
            scope, editedRange: NSRange(location: 10, length: 0), changeInLength: -50)
        #expect(collapse.length == 0)
        // An insertion exactly at the scope start shifts it; exactly at its end does not.
        let atStart = FindSelectionScope.adjusted(
            scope, editedRange: NSRange(location: 10, length: 2), changeInLength: 2)
        #expect(atStart == NSRange(location: 12, length: 10))
        let atEnd = FindSelectionScope.adjusted(
            scope, editedRange: NSRange(location: 20, length: 2), changeInLength: 2)
        #expect(atEnd == scope)
    }

    @Test("Find summary wording")
    func findSummary() {
        #expect(FindBarPresentation.matchSummary(matchCount: 0, currentIndex: nil) == "No results")
        #expect(FindBarPresentation.matchSummary(matchCount: 1, currentIndex: 0) == "1 of 1")
        #expect(FindBarPresentation.matchSummary(matchCount: 7, currentIndex: 2) == "3 of 7")
        #expect(FindBarPresentation.matchSummary(matchCount: 7, currentIndex: nil) == "1 of 7")
    }

    // MARK: - E6: search results

    @Test("Result snippet is cut around the match")
    func snippetAroundMatch() {
        let line =
            "    let result = performExpensiveWorkspaceSearch(query: text, options: [.caseSensitive])"
        let column = (line as NSString).range(of: "performExpensive").location + 1
        let snippet = SearchResultSnippet.make(
            preview: line, column: column, matchLength: "performExpensive".utf16.count,
            contextAfter: 20)
        #expect(snippet.match == "performExpensive")
        #expect(snippet.prefix == "let result = ")
        #expect(snippet.suffix == "WorkspaceSearch(quer…")
    }

    @Test("Result snippet trims a long lead-in and keeps short lines whole")
    func snippetLeadingContext() {
        let line = String(repeating: "a", count: 60) + "NEEDLE" + "tail"
        let snippet = SearchResultSnippet.make(
            preview: line, column: 61, matchLength: 6)
        #expect(snippet.prefix.hasPrefix("…"))
        #expect(snippet.prefix.count == 1 + 24)
        #expect(snippet.match == "NEEDLE")
        #expect(snippet.suffix == "tail")

        let short = SearchResultSnippet.make(preview: "foo bar", column: 5, matchLength: 3)
        #expect(short == SearchResultSnippet(prefix: "foo ", match: "bar", suffix: ""))
    }

    @Test("Result snippet survives a match beyond the clipped preview and multi-line matches")
    func snippetEdgeCases() {
        let beyond = SearchResultSnippet.make(preview: "  short", column: 500, matchLength: 4)
        #expect(beyond == SearchResultSnippet(prefix: "short", match: "", suffix: ""))

        let multiline = SearchResultSnippet.make(preview: "x = foo(", column: 5, matchLength: 400)
        #expect(multiline.prefix == "x = ")
        #expect(multiline.match == "foo(")
        #expect(multiline.suffix == "")

        let long = SearchResultSnippet.make(
            preview: "ab" + String(repeating: "m", count: 100), column: 3, matchLength: 100)
        #expect(long.match.count == 48)
        #expect(long.suffix.hasSuffix("…"))
    }

    @Test("Result file header splits name and folder")
    func pathParts() {
        let nested = SearchResultPathParts.split("Sources/RafuApp/Views/A.swift")
        #expect(nested.name == "A.swift")
        #expect(nested.folder == "Sources/RafuApp/Views")
        let root = SearchResultPathParts.split("Package.swift")
        #expect(root.name == "Package.swift")
        #expect(root.folder == "")
    }

    // MARK: - E8 / E9

    @Test("Markdown mode control reads Source | Preview | Split")
    @MainActor
    func markdownModeWords() {
        #expect(
            MarkdownPresentationMode.allCases.map(MarkdownModePresentation.title(for:))
                == ["Source", "Preview", "Split"])
        for mode in MarkdownPresentationMode.allCases {
            #expect(!MarkdownModePresentation.tooltip(for: mode).isEmpty)
        }
    }

    @Test("Palette footer legend uses key words, not pictograms")
    func paletteFooter() {
        #expect(PaletteFooterHints.text == "↑↓ Navigate · ↩ Open · esc Close")
    }

    // MARK: - E11: Resources

    @Test("Resources summary line")
    func resourcesSummary() {
        let terminal = ProcessResourceRegistry.ProcessResourceSample(
            id: UUID(), name: "zsh", kind: .terminalShell, pid: 1, residentBytes: 600_000)
        let terminal2 = ProcessResourceRegistry.ProcessResourceSample(
            id: UUID(), name: "zsh", kind: .terminalShell, pid: 2, residentBytes: 600_000)
        let group = MemoryProcessGroup(
            kind: .terminalShell, rows: [terminal, terminal2], totalBytes: 1_200_000)
        let line = ResourceSummary.line(
            appBytes: 152_000_000, groups: [group], languageServerCount: 0)
        #expect(line == "Rafu 145.0 MB · 2 terminals 1.1 MB · 0 language servers")

        let none = ResourceSummary.line(appBytes: nil, groups: [], languageServerCount: 1)
        #expect(none == "Rafu — · 0 terminals · 1 language server")
    }

    @Test("Resources popover is as tall as its content, capped at window height minus 40")
    func popoverHeight() {
        #expect(
            ResourcesPopoverLayout.scrollHeight(
                headerHeight: 100, contentHeight: 200, windowHeight: 800) == 200)
        #expect(
            ResourcesPopoverLayout.scrollHeight(
                headerHeight: 100, contentHeight: 2_000, windowHeight: 800) == 660)
        // Never collapses below a usable minimum in a tiny window.
        #expect(
            ResourcesPopoverLayout.scrollHeight(
                headerHeight: 100, contentHeight: 2_000, windowHeight: 200) == 160)
        // No window known: fall back to a sane height.
        #expect(
            ResourcesPopoverLayout.scrollHeight(
                headerHeight: 100, contentHeight: 2_000, windowHeight: nil) == 460)
    }

    // MARK: - E12: status bar

    @Test("Status bar language-server item reports count and worst state")
    func languageServerStatusItem() {
        #expect(StatusBarLanguageServerFormatter.present(phases: []) == nil)
        let running = StatusBarLanguageServerFormatter.present(phases: [.ready, .idle])
        #expect(running?.label == "2 language servers")
        #expect(running?.symbol == "cpu")
        let one = StatusBarLanguageServerFormatter.present(phases: [.ready])
        #expect(one?.label == "1 language server")
        let starting = StatusBarLanguageServerFormatter.present(phases: [.ready, .starting])
        #expect(starting?.label == "1 starting")
        let stopped = StatusBarLanguageServerFormatter.present(phases: [.starting, .dead])
        #expect(stopped?.label == "1 stopped")
        #expect(stopped?.symbol == "exclamationmark.triangle")
    }

    @Test("Status bar no longer repeats the connection state as 'Local editor'")
    func statusBarSource() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceStatusBar.swift")
        #expect(!source.contains("Local editor"))
        #expect(source.contains("ResidentMemoryMonitor.shared"))
        let resources = try Self.source("Sources/RafuApp/Views/ResourcesView.swift")
        #expect(resources.contains("ResidentMemoryMonitor.shared"))
    }

    // MARK: - E2 / G1 / gold budget contracts

    @Test("The workspace window keeps the standard window buttons visible")
    func windowButtonsVisible() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        #expect(source.contains("hidesTrafficLights: false"))
        #expect(source.contains("WindowTitlebarRow("))
        #expect(!source.contains("trafficLightsRevealed"))
        #expect(WindowTitlebarRow.height == 28)
    }

    @Test("Shared secondary controls carry no accent")
    func sharedControlsAreNeutral() throws {
        let source = try Self.source("Sources/RafuApp/Support/RafuControlStyles.swift")
        let icon = try Self.section(
            of: source, from: "struct RafuIconButtonStyle", to: "struct RafuRailButtonStyle")
        #expect(!icon.contains("palette.accent"))
        let secondary = try Self.section(
            of: source, from: "struct RafuSecondaryButtonStyle",
            to: "struct RafuSegmentedPicker")
        #expect(!secondary.contains("palette.accent"))
        let toggle = try Self.section(
            of: source, from: "struct RafuOptionToggle", to: "struct RafuChip")
        #expect(!toggle.contains("palette.accent"))
        #expect(source.contains("rafuNoWrapSegmentLabel"))
    }

    @Test("Files header leads with the workspace name and offers Filter Files")
    func filesHeader() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceSidebarView.swift")
        #expect(source.contains("\"Filter Files\", systemImage: \"magnifyingglass\""))
        #expect(source.contains(".font(.system(size: 13, weight: .semibold))"))
        #expect(!source.contains("Button(\"Search Workspace\""))
    }

    @Test("Native secondary menus explicitly override the inherited gold tint")
    func nativeMenusAreNeutral() throws {
        // CanvasAddMenu.swift is not scanned: the bar's "+" is now a button
        // that opens the Add palette, so that file has no pull-down left.
        for path in [
            "Sources/RafuApp/Views/GitInspectorView.swift",
            "Sources/RafuApp/Canvas/Views/CanvasBar.swift",
        ] {
            let source = try Self.source(path)
            let menus = source.components(separatedBy: ".menuStyle(.borderlessButton)").dropFirst()
            #expect(!menus.isEmpty)
            for menu in menus {
                #expect(
                    menu.trimmingCharacters(in: .whitespacesAndNewlines)
                        .hasPrefix(".tint(theme.palette.textSecondary)"), Comment(rawValue: path))
            }
        }
    }

    @Test("Large cards cannot expand the Canvas viewport or push controls off screen")
    func canvasViewportStaysBounded() throws {
        let source = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        #expect(
            source.contains(
                ".frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)"
            ))
    }

    @Test(
        "Canvas link notices use current bridge state and edge pills keep intrinsic width up to the gap"
    )
    func canvasLinkStatusLayout() throws {
        let source = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        #expect(!source.contains("@State private var pausedLinkCount"))
        #expect(source.contains("private var pausedLinkCount: Int"))
        #expect(source.contains("if showsRestoredLinksNotice && pausedLinkCount > 0"))
        let pill = try Self.source("Sources/RafuApp/Canvas/Views/CanvasEdgeLayer.swift")
        // A pill keeps its text's own width, capped at the space between the
        // cards beside it (round 3): a long label truncates, never wraps.
        #expect(pill.contains("CanvasEdgeLabelWidthLayout("))
        #expect(pill.contains("child.sizeThatFits(.unspecified)"))
        #expect(pill.contains(".lineLimit(1)"))
    }

    @Test("The paused-links notice stacks below the tool palette, never over it")
    func pausedLinksNoticeStacksBelowPalette() throws {
        let source = try Self.source("Sources/RafuApp/Canvas/Views/WorkspaceCanvasView.swift")
        let start = try #require(source.range(of: "private var boardTopOverlay: some View {"))
        let end = try #require(
            source.range(
                of: "private var pausedLinksNotice", range: start.upperBound..<source.endIndex))
        let overlay = String(source[start.upperBound..<end.lowerBound])
        // One vertical stack: the palette first, then the notice.
        let stack = try #require(
            overlay.range(of: "VStack(spacing: CanvasBoardTopOverlayMetrics.spacing)"))
        let palette = try #require(overlay.range(of: "CanvasToolPalette("))
        let notice = try #require(overlay.range(of: "pausedLinksNotice"))
        #expect(stack.lowerBound < palette.lowerBound)
        #expect(palette.lowerBound < notice.lowerBound)
        #expect(overlay.contains("if showsRestoredLinksNotice && pausedLinkCount > 0"))
        // The board surface shows the palette only through this stack: one
        // construction, so the split yields two pieces. The List view and
        // its separate top notice are gone.
        #expect(source.components(separatedBy: "CanvasToolPalette(").count == 2)
        #expect(!source.contains("board.showsList"))

        // The palette no longer places itself, so it cannot overlap.
        let paletteFile = try Self.source(
            "Sources/RafuApp/Canvas/Whiteboard/CanvasToolPalette.swift")
        #expect(
            !paletteFile.contains(
                ".frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)"))
        #expect(CanvasBoardTopOverlayMetrics.spacing == 8)
    }

    private static func section(of source: String, from start: String, to end: String) throws
        -> String
    {
        let startRange = try #require(source.range(of: start))
        let tail = source[startRange.lowerBound...]
        let endRange = try #require(tail.range(of: end))
        return String(tail[..<endRange.lowerBound])
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(
                    contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw WorkbenchChromeRedesignError.repositoryRootNotFound
    }

    private enum WorkbenchChromeRedesignError: Error {
        case repositoryRootNotFound
    }
}
