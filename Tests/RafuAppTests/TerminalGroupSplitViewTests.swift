import AppKit
import Foundation
import Testing

@testable import RafuApp

@Suite("Terminal Group split bridge")
struct TerminalGroupSplitViewTests {
    @Test("Invalid divider fractions fall back to the snapshot default")
    func invalidFractionsFallBack() {
        #expect(TerminalGroupSplitPresentation.normalizedFraction(.nan) == 0.5)
        #expect(TerminalGroupSplitPresentation.normalizedFraction(.infinity) == 0.5)
        #expect(TerminalGroupSplitPresentation.normalizedFraction(-1) == 0.1)
        #expect(TerminalGroupSplitPresentation.normalizedFraction(2) == 0.9)
    }

    @Test("Minimum pane sizes clamp only the effective display fraction")
    func minimumSizeClampDoesNotChangeSavedFraction() {
        let saved = 0.2
        let constrained = TerminalGroupSplitPresentation.effectiveFraction(
            savedFraction: saved,
            availableLength: 200,
            minimumPaneLength: 80
        )
        let restored = TerminalGroupSplitPresentation.effectiveFraction(
            savedFraction: saved,
            availableLength: 1_000,
            minimumPaneLength: 80
        )

        #expect(constrained == 0.4)
        #expect(restored == saved)
    }

    @MainActor
    @Test("AppKit constrains both divider bounds and restores the saved fraction after resize")
    func appKitDividerConstraintsAndResizeRestore() {
        let splitView = TerminalGroupNSSplitView(frame: NSRect(x: 0, y: 0, width: 201, height: 200))
        splitView.isVertical = true
        splitView.minimumPaneLength = 120
        splitView.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 200)))
        splitView.addArrangedSubview(NSView(frame: NSRect(x: 101, y: 0, width: 100, height: 200)))
        splitView.adjustSubviews()

        let usableLength = splitView.bounds.width - splitView.dividerThickness
        let constrainedMinimum = min(splitView.minimumPaneLength, usableLength / 2)
        #expect(splitView.minimumDividerCoordinate == constrainedMinimum)
        #expect(splitView.maximumDividerCoordinate == constrainedMinimum)
        #expect(
            splitView.splitView(
                splitView,
                constrainMinCoordinate: 0,
                ofSubviewAt: 0
            ) == constrainedMinimum
        )
        #expect(
            splitView.splitView(
                splitView,
                constrainMaxCoordinate: usableLength,
                ofSubviewAt: 0
            ) == constrainedMinimum
        )

        var callbacks: [Double] = []
        splitView.onUserDividerChange = { callbacks.append($0) }
        splitView.applySavedFraction(0.2)
        #expect(abs(splitView.subviews[0].frame.width - (usableLength / 2)) < 1)
        #expect(callbacks.isEmpty)

        splitView.setFrameSize(NSSize(width: 1_001, height: 200))
        splitView.resizeSubviews(withOldSize: NSSize(width: 201, height: 200))
        let restoredUsableLength = splitView.bounds.width - splitView.dividerThickness
        #expect(abs(splitView.subviews[0].frame.width - (restoredUsableLength * 0.2)) < 1)
        #expect(callbacks.isEmpty)
    }

    @MainActor
    @Test("Divider tracking keeps its live position and emits one user callback")
    func dividerTrackingDoesNotSnapBack() {
        let splitView = TerminalGroupNSSplitView(frame: NSRect(x: 0, y: 0, width: 201, height: 200))
        splitView.isVertical = true
        splitView.addArrangedSubview(NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 200)))
        splitView.addArrangedSubview(NSView(frame: NSRect(x: 101, y: 0, width: 100, height: 200)))
        splitView.adjustSubviews()
        splitView.applySavedFraction(0.5)
        var callbacks: [Double] = []
        splitView.onUserDividerChange = { callbacks.append($0) }

        splitView.beginUserDividerDrag()
        let draggedPosition = (splitView.bounds.width - splitView.dividerThickness) * 0.7
        splitView.setPosition(draggedPosition, ofDividerAt: 0)
        splitView.applySavedFraction(0.5)

        #expect(abs(splitView.subviews[0].frame.width - draggedPosition) < 1)
        splitView.completeUserDividerDrag()
        #expect(callbacks.count == 1)
        #expect(abs(callbacks[0] - 0.7) < 0.001)

        splitView.applySavedFraction(0.3)
        let updatedPosition = (splitView.bounds.width - splitView.dividerThickness) * 0.5
        #expect(abs(splitView.subviews[0].frame.width - updatedPosition) < 1)
    }

    @Test("The bridge uses AppKit only for persistent divider interaction")
    func sourceContractKeepsSnapshotAuthority() throws {
        let source = try Self.source("Sources/RafuApp/Terminal/TerminalGroupSplitView.swift")

        #expect(source.contains("NSSplitView"))
        #expect(source.contains("axis == .columns"))
        #expect(source.contains("onUserDividerChange"))
        #expect(source.contains("applySavedFraction"))
        #expect(source.contains("constrainMinCoordinate"))
        #expect(source.contains("constrainMaxCoordinate"))
        #expect(source.contains("override func resizeSubviews"))
        #expect(source.contains("!isDraggingDivider"))
        #expect(source.contains("guard !isDraggingDivider else { return }"))
        #expect(source.contains("savedFraction = finalFraction"))
        #expect(source.contains("dragStartFraction"))
        #expect(source.contains("abs(finalFraction - dragStartFraction)"))
        #expect(!source.contains("WorkspaceSession"))
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
        throw TerminalGroupSplitViewTestError.repositoryRootNotFound
    }

    private enum TerminalGroupSplitViewTestError: Error {
        case repositoryRootNotFound
    }
}
