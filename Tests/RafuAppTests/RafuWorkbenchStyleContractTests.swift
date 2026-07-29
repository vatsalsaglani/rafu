import Foundation
import Testing

@testable import RafuApp

@Suite("Workbench presentation foundation")
@MainActor
struct RafuWorkbenchStyleContractTests {
    @Test("Compact workbench metrics are semantic and exact")
    func compactMetrics() {
        #expect(RafuMetrics.workbenchInset == 4)
        #expect(RafuMetrics.editorGroupGapTarget == 4)
        #expect(RafuMetrics.radiusWorkbenchDeck == 6)
        #expect(RafuMetrics.radiusEditorGroup == 5)
        #expect(RafuMetrics.radiusAttachedTab == 4)
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

    @Test("Selected attached tabs fill, outline three edges, and mask only the shelf seam")
    func attachedTabGeometry() {
        let inactive = AttachedWorkbenchTabPresentation.resolve(isSelected: false)
        #expect(inactive.fill == .clear)
        #expect(inactive.outlineEdges.isEmpty)
        #expect(!inactive.masksBottomSeam)

        let selected = AttachedWorkbenchTabPresentation.resolve(isSelected: true)
        #expect(selected.fill == .tabActiveBackground)
        #expect(selected.outline == .borderStrong)
        #expect(selected.outlineEdges == [.top, .leading, .trailing])
        #expect(!selected.outlineEdges.contains(.bottom))
        #expect(selected.masksBottomSeam)
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

    @Test("Terminal editor focus strengthens structure and reserves identity geometry")
    func editorTerminalBorderPrecedence() throws {
        let resting = TerminalSurfaceBorderStyle.resolve(
            context: .editorGroup(isFocused: false),
            identity: .assigned(matchesEditorBackground: true),
            contrast: .normal
        )
        #expect(resting.neutralStructure == .borderSubtle)
        #expect(resting.neutralWidth == 1)
        #expect(resting.showsIdentityAccent)
        #expect(resting.identityWidth == 1)
        #expect(resting.identityInset == 1)
        #expect(resting.emphasis == .none)
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
        #expect(focused.emphasisWidth == 2)
        #expect(focused.identityInset == 2)
        #expect(focused.identityInset >= focused.emphasisWidth)
        #expect(focused.identityInset > resting.identityInset)
        #expect(focused.rowFill == .none)

        let source = try Self.workbenchStyleSource()
        #expect(
            source.contains(
                "cornerRadius: max(0, radius - resolution.identityInset)"
            )
        )
        #expect(source.contains(".padding(resolution.identityInset)"))
        #expect(!source.contains(".padding(resolution.neutralWidth)"))
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

    @Test("Terminal status stays outside border, identity, focus, current, and attention inputs")
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
        #expect(resolverSource.contains("case editorGroup(isFocused: Bool)"))
        #expect(resolverSource.contains("case managerRow(isCurrent: Bool, needsAttention: Bool)"))
        #expect(!resolverSource.contains("status:"))
        #expect(source.contains("Status is deliberately not an input"))
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
    }

    private static func workbenchStyleSource() throws -> String {
        try source("Sources/RafuApp/Support/RafuWorkbenchStyles.swift")
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
