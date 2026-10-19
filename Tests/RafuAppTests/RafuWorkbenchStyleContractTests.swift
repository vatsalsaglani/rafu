import Foundation
import Testing

@testable import RafuApp

@Suite("Workbench presentation foundation")
@MainActor
struct RafuWorkbenchStyleContractTests {
    @Test("Compact workbench metrics are semantic and exact")
    func compactMetrics() {
        // Design polish round 2: the inset grew 8 → 10 so the stronger deck
        // shadow (radius 6 → 7, y 2 → 3) still fits inside the gutter.
        #expect(RafuMetrics.workbenchInset == 10)
        #expect(RafuMetrics.editorGroupGapTarget == 4)
        #expect(RafuMetrics.radiusWorkbenchDeck == 12)
        #expect(RafuMetrics.radiusEditorGroup == 5)
        #expect(RafuMetrics.deckShadowRadius == 7)
        #expect(RafuMetrics.deckShadowY == 3)
        // The shadow must stay inside the deck lane's 10 pt gutter, or the
        // lane would clip it.
        #expect(
            RafuMetrics.deckShadowRadius + RafuMetrics.deckShadowY <= RafuMetrics.workbenchInset)
        #expect(RafuMetrics.radiusWorkbenchTab == 10)
        #expect(RafuMetrics.tabShadowRadius == 3)
        #expect(RafuMetrics.tabShadowY == 1)
        #expect(RafuMetrics.tabLabelFontSize == 12.5)
        // Round 2 tightened the shelf (breathing room 6 → 5, floor 40 → 38)
        // and grew the breadcrumb row beneath it (24 → 26).
        #expect(RafuMetrics.tabShelfBreathingRoom == 5)
        #expect(RafuMetrics.tabShelfHeight == 38)
        #expect(
            RafuMetrics.tabShelfHeight
                == RafuMetrics.tabBarHeight + RafuMetrics.tabShelfBreathingRoom * 2)
        #expect(RafuMetrics.breadcrumbHeight == 26)
        #expect(RafuMetrics.breadcrumbHorizontalPadding == 12)
        #expect(RafuMetrics.radiusDenseSelection == 4)
        #expect(RafuMetrics.radiusDenseCard == 6)
        #expect(RafuMetrics.radiusWorkbenchField == 5)
        #expect(RafuMetrics.radiusTransientPopover == 8)
        #expect(RafuMetrics.utilityBodyInset == 8)
        #expect(RafuMetrics.settingsSectionInset == 14)
        #expect(RafuMetrics.settingsRowMinHeight == 36)
        #expect(RafuMetrics.settingsSectionGap == 28)
        #expect(RafuMetrics.terminalBorderWidth == 1)
        #expect(RafuMetrics.focusedTerminalBorderWidth == 2)
        #expect(RafuMetrics.radiusPanel == 12)
        #expect(RafuMetrics.tabBarHeight == 28)
        #expect(RafuMetrics.sectionHeaderHeight == 34)
        #expect(RafuMetrics.statusBarHeight == 24)
    }

    @Test("Deck and group helpers decorate without clipping or masking content")
    func surfacesDoNotClipContent() throws {
        let source = try Self.workbenchStyleSource()
        #expect(source.contains("struct WorkbenchDeckSurface<Content: View>"))
        #expect(source.contains("struct EditorGroupSurface<Content: View>"))
        #expect(!source.contains(".clipShape("))
        #expect(!source.contains(".mask("))
    }

    @Test(
        "The raised deck and the selected tab cast the window's only two shadows, both through the shared theme-aware helper, never on content"
    )
    func deckIsTheOnlyShadowSource() throws {
        let workbenchSource = try Self.workbenchStyleSource()
        // Window redesign phase 4 adds exactly one more shadow: the selected
        // tab card. Both go through `WorkbenchDeckShadowStyle`.
        #expect(Self.occurrences(of: ".shadow(", in: workbenchSource) == 2)
        #expect(
            Self.occurrences(of: "WorkbenchDeckShadowStyle.color(", in: workbenchSource) == 2
        )

        let deckSection = try Self.section(
            of: workbenchSource,
            from: "struct WorkbenchDeckSurface<Content: View>",
            to: "enum WorkbenchDeckShadowStyle"
        )
        #expect(deckSection.contains(".shadow("))
        // The shadow lives on a dedicated `RoundedRectangle` background
        // shape, which sits before the content-touching `.overlay` that
        // draws the border — never directly on `content` itself.
        let shapeFill = try #require(deckSection.range(of: ".fill(theme.palette.editorBackground)"))
        let shadowCall = try #require(deckSection.range(of: ".shadow("))
        let contentOverlay = try #require(deckSection.range(of: ".overlay {"))
        #expect(shapeFill.lowerBound < shadowCall.lowerBound)
        #expect(shadowCall.lowerBound < contentOverlay.lowerBound)

        let tabSection = try Self.section(
            of: workbenchSource,
            from: "struct AttachedWorkbenchTab<Content: View>: View",
            to: "/// What the trailing slot of an editor tab shows."
        )
        #expect(tabSection.contains(".shadow("))
        #expect(tabSection.contains("WorkbenchDeckShadowStyle.color("))
        #expect(tabSection.contains("for: .tab,"))
        #expect(deckSection.contains("for: .deck,"))
        #expect(tabSection.contains("RafuMetrics.tabShadowRadius"))
        #expect(tabSection.contains("RafuMetrics.tabShadowY"))

        let windowSource = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        #expect(!windowSource.contains(".shadow("))
    }

    @Test("Deck and tab shadow opacities are theme-aware and Increase Contrast subdues them")
    func deckShadowOpacityIsThemeAware() {
        // Design polish round 2: the deck's dark opacity rose 0.18 → 0.30 so
        // the card lifts off the darker Indigo frame; the selected tab got
        // its own, stronger value because its shadow is much tighter.
        let dark = WorkbenchDeckShadowStyle.opacity(for: .deck, isDark: true)
        let light = WorkbenchDeckShadowStyle.opacity(for: .deck, isDark: false)
        #expect(dark == 0.30)
        #expect(light == 0.10)
        #expect(dark > light)
        #expect(WorkbenchDeckShadowStyle.opacity(isDark: true) == dark)

        let tabDark = WorkbenchDeckShadowStyle.opacity(for: .tab, isDark: true)
        let tabLight = WorkbenchDeckShadowStyle.opacity(for: .tab, isDark: false)
        #expect(tabDark == 0.40)
        #expect(tabLight == 0.12)
        #expect(tabDark > tabLight)

        for surface in [WorkbenchDeckShadowStyle.Surface.deck, .tab] {
            for isDark in [true, false] {
                #expect(
                    WorkbenchDeckShadowStyle.opacity(
                        for: surface, isDark: isDark, contrastIncreased: true)
                        == WorkbenchDeckShadowStyle.opacity(for: surface, isDark: isDark) / 2
                )
            }
        }
    }

    @Test("Corner and seam overlays cannot intercept input or accessibility")
    func overlaysAreInert() throws {
        let source = try Self.workbenchStyleSource()
        let inertOverlayCount =
            source.components(separatedBy: ".allowsHitTesting(false)").count - 1
        let hiddenOverlayCount =
            source.components(separatedBy: ".accessibilityHidden(true)").count - 1
        #expect(inertOverlayCount >= 8)
        #expect(hiddenOverlayCount >= 8)
        #expect(source.contains("struct CornerCutoutOverlay: View"))
        #expect(source.contains("FillStyle(eoFill: true)"))
    }

    @Test("Inactive tabs are unfilled; the selected tab is a fully outlined raised card")
    func attachedTabGeometry() throws {
        let inactive = AttachedWorkbenchTabPresentation.resolve(isSelected: false)
        #expect(inactive.fill == .clear)
        #expect(inactive.outline == .clear)
        #expect(inactive.outlineEdges.isEmpty)

        let selected = AttachedWorkbenchTabPresentation.resolve(isSelected: true)
        #expect(selected.fill == .tabActiveBackground)
        #expect(selected.outline == .borderSubtle)
        #expect(selected.outlineEdges == [.top, .leading, .trailing, .bottom])

        let source = try Self.workbenchStyleSource()
        #expect(source.contains("case .tabActiveBackground: tabActiveBackground"))
        let tabSection = try Self.section(
            of: source,
            from: "struct AttachedWorkbenchTab<Content: View>: View",
            to: "/// What the trailing slot of an editor tab shows."
        )
        // Increase Contrast promotes the selected hairline; hover washes only
        // an unselected tab.
        #expect(tabSection.contains("contrastIncreased: colorSchemeContrast == .increased"))
        #expect(tabSection.contains("!isSelected && isHovering"))
        #expect(tabSection.contains("theme.palette.hover"))
        // Weight marks the selected tab for every tab kind, not colour alone.
        #expect(tabSection.contains("size: RafuMetrics.tabLabelFontSize"))
        #expect(tabSection.contains("weight: isSelected ? .semibold : .medium"))
    }

    @Test("Text-bearing chrome uses scalable minimums instead of fixed clipping boxes")
    func textBearingMinimumHeightPolicy() {
        #expect(WorkbenchTextHeightPolicy.attachedTabHeight(for: 24) == 28)
        #expect(WorkbenchTextHeightPolicy.attachedTabHeight(for: 31) == 31)
        #expect(WorkbenchTextHeightPolicy.attachedTabHeight(for: 40) == 34)
        #expect(WorkbenchTextHeightPolicy.minimumHeight(base: 34, scaledHeight: 30) == 34)
        #expect(WorkbenchTextHeightPolicy.minimumHeight(base: 34, scaledHeight: 42) == 42)
        #expect(WorkbenchTextHeightPolicy.attachedTabCloseTarget(for: 18) == 22)
        #expect(WorkbenchTextHeightPolicy.attachedTabCloseTarget(for: 26) == 26)
        #expect(WorkbenchTextHeightPolicy.attachedTabCloseTarget(for: 34) == 28)
    }

    @Test("Assigned identity stays dominant while editor focus uses a separate outer edge")
    func editorTerminalBorderPrecedence() throws {
        let resting = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false),
            identity: .assigned(matchesEditorBackground: true),
            contrast: .normal
        )
        #expect(resting.neutralStructure == .borderSubtle)
        #expect(resting.neutralWidth == 1)
        #expect(resting.showsIdentityAccent)
        #expect(resting.identityWidth == 2)
        #expect(resting.identityInset == 1)
        #expect(resting.emphasis == .none)
        #expect(resting.emphasisWidth == 0)
        #expect(resting.drawOrder == [.neutralStructure, .emphasis, .identity])
        #expect(resting.rowFill == .none)

        let focused = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: true),
            identity: .assigned(matchesEditorBackground: true),
            contrast: .normal
        )
        #expect(focused.neutralStructure == .borderStrong)
        #expect(focused.showsIdentityAccent)
        #expect(focused.emphasis == .editorFocus)
        #expect(focused.emphasisRole == .focusRing)
        #expect(focused.emphasisWidth == 1)
        #expect(focused.emphasisInset == 0)
        #expect(focused.identityWidth == 2)
        #expect(focused.identityInset == 1)
        #expect(focused.identityAndEmphasisDoNotOverlap)
        #expect(focused.drawOrder == [.neutralStructure, .emphasis, .identity])
        #expect(focused.identityInset == resting.identityInset)
        #expect(focused.rowFill == .none)

        let source = try Self.workbenchStyleSource()
        #expect(
            source.contains(
                "cornerRadius: max(0, radius - resolution.identityInset)"
            )
        )
        #expect(source.contains(".padding(resolution.identityInset)"))
        #expect(source.contains(".padding(resolution.emphasisInset)"))
        let emphasisLayer = try #require(source.range(of: "if resolution.emphasis != .none"))
        let identityLayer = try #require(
            source.range(of: "if resolution.showsIdentityAccent, let identityColor")
        )
        #expect(emphasisLayer.lowerBound < identityLayer.lowerBound)
    }

    @Test("Terminal resolver geometry matrix preserves every signal and contrast state")
    func terminalResolverGeometryMatrix() {
        let identities: [TerminalSurfaceIdentity] = [
            .none,
            .assigned(matchesEditorBackground: false),
            .assigned(matchesEditorBackground: true),
        ]
        let contexts: [TerminalSurfaceBorderStyle.Context] = [
            .editorGroup(isFocused: false),
            .editorGroup(isFocused: true),
            .editorGroup(isFocused: true, hostsTerminal: true),
            .editorGroup(isFocused: true, hasSiblings: true),
            .managerRow(isCurrent: false, needsAttention: false),
            .managerRow(isCurrent: true, needsAttention: false),
            .managerRow(isCurrent: false, needsAttention: true),
            .managerRow(isCurrent: true, needsAttention: true),
        ]
        let contrasts: [TerminalSurfaceContrast] = [.normal, .increased]

        for identity in identities {
            for context in contexts {
                for contrast in contrasts {
                    let resolution = TerminalSurfaceBorderStyle.resolve(
                        context: context,
                        identity: identity,
                        contrast: contrast
                    )
                    let hasIdentity = identity != .none
                    #expect(resolution.neutralWidth == 1)
                    #expect(resolution.showsIdentityAccent == hasIdentity)
                    #expect(resolution.identityWidth == (hasIdentity ? 2 : 0))
                    #expect(resolution.identityInset == (hasIdentity ? 1 : 0))
                    #expect(resolution.emphasisInset == 0)
                    #expect(resolution.identityAndEmphasisDoNotOverlap)
                    #expect(
                        resolution.drawOrder
                            == (hasIdentity
                                ? [.neutralStructure, .emphasis, .identity]
                                : [.neutralStructure, .emphasis])
                    )

                    let expectsStrongNeutral: Bool =
                        switch context {
                        case .editorGroup(let isFocused, let hostsTerminal, _):
                            (isFocused && (hostsTerminal || hasIdentity))
                                || contrast == .increased
                        case .managerRow(let isCurrent, let needsAttention):
                            isCurrent || needsAttention || contrast == .increased
                        }
                    #expect(
                        resolution.neutralStructure
                            == (expectsStrongNeutral ? .borderStrong : .borderSubtle)
                    )

                    switch context {
                    case .editorGroup(let isFocused, let hostsTerminal, let hasSiblings):
                        let terminalFocus = isFocused && (hostsTerminal || hasIdentity)
                        let siblingFocus = isFocused && hasSiblings && !terminalFocus
                        #expect(resolution.rowFill == .none)
                        #expect(
                            resolution.emphasis
                                == (terminalFocus || siblingFocus ? .editorFocus : .none))
                        #expect(
                            resolution.emphasisWidth
                                == (terminalFocus ? (hasIdentity ? 1 : 2) : (siblingFocus ? 1 : 0))
                        )
                        // Gold only ever marks a focused terminal.
                        #expect((resolution.emphasisRole == .focusRing) == terminalFocus)
                    case .managerRow(let isCurrent, let needsAttention):
                        let expectedEmphasis: TerminalSurfaceBorderResolution.Emphasis =
                            needsAttention
                            ? .managerAttention : (isCurrent ? .managerCurrent : .none)
                        #expect(resolution.emphasis == expectedEmphasis)
                        #expect(resolution.emphasisWidth == (expectedEmphasis == .none ? 0 : 1))
                        #expect(resolution.rowFill == (isCurrent ? .current : .none))
                    }
                }
            }
        }
    }

    @Test("Increase Contrast promotes resting terminal structure without inventing emphasis")
    func terminalContrastPromotesNeutralStructure() throws {
        let normalEditor = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false),
            identity: .none,
            contrast: .normal
        )
        let increasedEditor = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false),
            identity: .none,
            contrast: .increased
        )
        #expect(normalEditor.neutralStructure == .borderSubtle)
        #expect(increasedEditor.neutralStructure == .borderStrong)
        #expect(increasedEditor.neutralWidth == normalEditor.neutralWidth)
        #expect(increasedEditor.emphasis == .none)

        let normalRow = TerminalSurfaceBorderStyle.resolve(
            context: .managerRow(isCurrent: false, needsAttention: false),
            identity: .none,
            contrast: .normal
        )
        let increasedRow = TerminalSurfaceBorderStyle.resolve(
            context: .managerRow(isCurrent: false, needsAttention: false),
            identity: .none,
            contrast: .increased
        )
        #expect(normalRow.neutralStructure == .borderSubtle)
        #expect(increasedRow.neutralStructure == .borderStrong)
        #expect(increasedRow.emphasis == .none)
        #expect(increasedRow.rowFill == .none)

        let source = try Self.workbenchStyleSource()
        #expect(source.contains("@Environment(\\.colorSchemeContrast)"))
        #expect(
            source.contains(
                "colorSchemeContrast == .increased ? .increased : .normal"
            )
        )
        #expect(source.contains("style.resolution(contrast: surfaceContrast)"))
    }

    @Test("Manager current, attention, and identity remain independent signals")
    func managerTerminalBorderPrecedence() {
        let current = TerminalSurfaceBorderStyle.resolve(
            context: .managerRow(isCurrent: true, needsAttention: false),
            identity: .none,
            contrast: .normal
        )
        #expect(!current.showsIdentityAccent)
        #expect(current.emphasis == .managerCurrent)
        #expect(current.emphasisRole == .focusRing)
        #expect(current.rowFill == .current)

        let attention = TerminalSurfaceBorderStyle.resolve(
            context: .managerRow(isCurrent: false, needsAttention: true),
            identity: .assigned(matchesEditorBackground: false),
            contrast: .normal
        )
        #expect(attention.showsIdentityAccent)
        #expect(attention.emphasis == .managerAttention)
        #expect(attention.emphasisRole == .warning)
        #expect(attention.identityWidth == 2)
        #expect(attention.identityInset == 1)
        #expect(attention.emphasisWidth == 1)
        #expect(attention.identityAndEmphasisDoNotOverlap)
        #expect(attention.rowFill == .none)

        let currentAttention = TerminalSurfaceBorderStyle.resolve(
            context: .managerRow(isCurrent: true, needsAttention: true),
            identity: .assigned(matchesEditorBackground: false),
            contrast: .normal
        )
        #expect(currentAttention.emphasis == .managerAttention)
        #expect(currentAttention.rowFill == .current)
        #expect(currentAttention.showsIdentityAccent)
    }

    @Test("Source policy excludes terminal status from border resolver inputs")
    func terminalStatusIsSeparate() throws {
        let source = try Self.workbenchStyleSource()
        let contract = try #require(
            source.range(
                of: "nonisolated struct TerminalSurfaceBorderStyle"
            )
        )
        let tail = source[contract.lowerBound...]
        let end = try #require(tail.range(of: "extension RafuThemePalette"))
        let resolverSource = String(tail[..<end.lowerBound])
        #expect(resolverSource.contains("case editorGroup(isFocused: Bool,"))
        #expect(resolverSource.contains("case managerRow(isCurrent: Bool, needsAttention: Bool)"))
        #expect(!resolverSource.contains("status:"))
    }

    @Test("Settings sections restore heading, containment, and source-order semantics")
    func settingsAccessibilityContract() throws {
        let source = try Self.workbenchStyleSource()
        #expect(source.contains("struct RafuSettingsSection<"))
        #expect(source.contains(".accessibilityAddTraits(.isHeader)"))
        #expect(source.contains(".accessibilityElement(children: .contain)"))
        #expect(source.contains("struct RafuSettingsRow<Content: View>"))
        #expect(source.contains("minHeight: RafuMetrics.settingsRowMinHeight"))
    }

    @Test("Rail style exposes every interaction state without decorative motion")
    func railStyleContract() throws {
        let source = try Self.source(
            "Sources/RafuApp/Support/RafuControlStyles.swift"
        )
        #expect(source.contains("struct RafuRailButtonStyle: ButtonStyle"))
        #expect(source.contains(".frame(width: 30, height: 30)"))
        #expect(source.contains("@Environment(\\.controlActiveState)"))
        #expect(source.contains("if configuration.isPressed"))
        #expect(source.contains("if isHovering"))
        #expect(source.contains(".help(tooltip)"))
        #expect(source.contains(".accessibilityAddTraits(isSelected ? .isSelected : [])"))
        #expect(source.contains("if let badge, badge > 0"))
        let railStart = try #require(source.range(of: "struct RafuRailButtonStyle"))
        let railTail = source[railStart.lowerBound...]
        let railEnd = try #require(railTail.range(of: "struct RafuProminentButtonStyle"))
        let railSource = String(railTail[..<railEnd.lowerBound])
        #expect(!railSource.contains(".animation("))
        // Selected is a filled rounded square: no hairline, no side bar.
        #expect(!railSource.contains("strokeBorder"))
        #expect(!railSource.contains(".frame(width: 2, height: 16)"))
        #expect(railSource.contains("cornerRadius: RafuMetrics.radiusField"))
        #expect(!railSource.contains("radiusDenseSelection"))
        #expect(railSource.contains("return theme.palette.selection"))
        #expect(railSource.contains(".font(.system(size: 14, weight: .medium))"))
    }

    @Test("The sidebar seam draws nothing at rest and a grab bar only on hover or drag")
    func sidebarSeamIsIdleClear() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkbenchSplitHandle.swift")
        let seam = try Self.section(
            of: source, from: "private var seam: some View", to: "// MARK: - Drag")
        let hoverBranch = try #require(seam.range(of: "if isHovering || isDragging {"))
        let grabBar = try #require(seam.range(of: ".fill(theme.palette.borderStrong)"))
        let idleBranch = try #require(seam.range(of: "} else {"))
        #expect(hoverBranch.lowerBound < grabBar.lowerBound)
        #expect(grabBar.lowerBound < idleBranch.lowerBound)
        let idle = String(seam[idleBranch.upperBound...])
        #expect(idle.contains("Color.clear"))
        #expect(!idle.contains(".fill("))
        #expect(!seam.contains("borderSubtle"))
        // Hit area, cursor, and VoiceOver adjustment are unchanged.
        #expect(source.contains("static let hitAreaWidth: CGFloat = 10"))
        #expect(source.contains("NSCursor.resizeLeftRight.push()"))
        #expect(source.contains(".accessibilityAdjustableAction(handleAccessibilityAdjustment)"))
    }

    private static func workbenchStyleSource() throws -> String {
        try source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
    }

    private static func occurrences(of needle: String, in source: String) -> Int {
        source.components(separatedBy: needle).count - 1
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
                    contentsOf: directory.appending(path: path),
                    encoding: .utf8
                )
            }
            directory = directory.deletingLastPathComponent()
        }
        throw WorkbenchStyleContractError.repositoryRootNotFound
    }

    private enum WorkbenchStyleContractError: Error {
        case repositoryRootNotFound
    }
}
