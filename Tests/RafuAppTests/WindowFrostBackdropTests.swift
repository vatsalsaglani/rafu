import AppKit
import Foundation
import SwiftUI
import Testing

@testable import RafuApp

/// The frosted window base's AppKit views and its source contracts: frame
/// surfaces paint through one modifier, the spike mechanisms are gone, and
/// the terminal keeps its opaque background (Step 3 is separate work).
@Suite("Window frost backdrop")
@MainActor
struct WindowFrostBackdropTests {
    @Test("The effect view blurs behind the window and stays active when inactive")
    func effectViewConfiguration() {
        let view = WindowFrostPassthroughEffectView()
        WindowFrostEffectView.apply(mask: nil, to: view)

        #expect(view.blendingMode == .behindWindow)
        #expect(view.material == .hudWindow)
        #expect(view.state == .active)
        #expect(view.maskImage == nil)
    }

    @Test("The effect view never takes a click")
    func effectViewPassesClicksThrough() {
        let view = WindowFrostPassthroughEffectView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        #expect(view.hitTest(NSPoint(x: 50, y: 50)) == nil)
    }

    @Test("Corner masks are made once, sized twice the radius, one per corner")
    func cornerMasks() {
        let radius = RafuMetrics.radiusWorkbenchDeck
        let masks = WindowFrostWedges.Corner.allCases.map {
            WindowFrostWedges.mask($0, radius: radius)
        }
        for mask in masks {
            #expect(mask.size == NSSize(width: radius * 2, height: radius * 2))
        }
        #expect(Set(masks.map(ObjectIdentifier.init)).count == 4)
        // Identity is stable, so `updateNSView` never rewrites `maskImage`.
        #expect(WindowFrostWedges.mask(.topLeading, radius: radius) === masks[0])

        let view = WindowFrostPassthroughEffectView()
        WindowFrostEffectView.apply(mask: masks[0], to: view)
        #expect(view.maskImage === masks[0])
    }

    @Test("The window surface defaults to Solid in the environment")
    func environmentDefault() {
        #expect(EnvironmentValues().rafuWindowSurface == .solid)
    }

    // MARK: Source contracts

    @Test("Every frame surface paints through rafuFrameSurface")
    func frameSurfacesUseOneModifier() throws {
        let expectations: [(String, String)] = [
            ("Sources/RafuApp/Views/WorkspaceTitlebarRow.swift", ".rafuFrameSurface(.app)"),
            ("Sources/RafuApp/Views/WorkspaceWindowView.swift", ".rafuFrameSurface(.app)"),
            ("Sources/RafuApp/Views/WorkspaceNavigatorView.swift", ".rafuFrameSurface(.sidebar)"),
            ("Sources/RafuApp/Views/WorkspaceSidebarView.swift", ".rafuFrameSurface(.sidebar)"),
            ("Sources/RafuApp/Views/WorkspaceStatusBar.swift", ".rafuFrameSurface(.statusBar)"),
        ]
        for (path, needle) in expectations {
            let source = try Self.source(path)
            #expect(source.contains(needle), "\(path) lacks \(needle)")
        }
        // No direct opaque frame fill is left on those surfaces.
        for path in Set(expectations.map(\.0)) {
            let source = try Self.source(path)
            for token in ["appBackground", "sidebarBackground", "statusBarBackground"] {
                #expect(
                    !source.contains(".background(theme.palette.\(token))"),
                    "\(path) paints \(token) directly")
            }
        }
    }

    @Test("The backdrop is mounted once, under the workbench, never for the welcome window")
    func backdropMount() throws {
        let source = try Self.source("Sources/RafuApp/Views/WorkspaceWindowView.swift")
        #expect(source.components(separatedBy: "WindowFrostBackdrop(").count - 1 == 1)
        #expect(source.contains("if windowSurface.isFrosted {"))
        #expect(source.contains("guard !showsWelcome else { return .solid }"))
        #expect(source.contains(".environment(\\.rafuWindowSurface, windowSurface)"))
        #expect(source.contains("reduceTransparency: reduceTransparency"))
        #expect(source.contains("increaseContrast: colorSchemeContrast == .increased"))
        // The window background stays the solid first-frame colour.
        #expect(!source.contains("isOpaque"))
    }

    @Test("No spike mechanism or debug default remains")
    func spikeIsGone() throws {
        let files = [
            "Sources/RafuApp/Views/WindowFrostBackdrop.swift",
            "Sources/RafuApp/Views/WorkspaceWindowView.swift",
            "Sources/RafuApp/Support/RafuWorkbenchStyles.swift",
            "Sources/RafuApp/Terminal/WorkspaceTerminalController.swift",
        ]
        for path in files {
            let source = try Self.source(path)
            for needle in [
                "FrostSpike", "frostSpike", "NSGlassEffectView", "glassEffect(",
                "containerBackground(", "isOpaque",
            ] {
                #expect(!source.contains(needle), "\(path) still contains \(needle)")
            }
        }
        // Step 3 landed (ADR 0038): the terminal background takes the
        // frosted content alpha, and the layer colour SwiftTerm set once in
        // `setupOptions` is cleared only while that alpha is below 1.
        let terminal = try Self.source(
            "Sources/RafuApp/Terminal/WorkspaceTerminalController.swift")
        #expect(
            terminal.contains(
                "Self.terminalBackground(background, alpha: backgroundAlpha)"))
        #expect(terminal.contains("if backgroundAlpha < 1 {"))
        #expect(terminal.contains("view.layer?.backgroundColor = NSColor.clear.cgColor"))
    }

    @Test("Settings offers Window background and Frost, with the forced-Solid footnote")
    func settingsSection() throws {
        let section = try Self.source(
            "Sources/RafuApp/Settings/WindowSurfaceSettingsSection.swift")
        #expect(section.contains("LabeledContent(\"Window background\")"))
        #expect(section.contains("LabeledContent(\"Frost\")"))
        #expect(section.contains(".disabled(!isFrostedSelected || forcedSolidReason != nil)"))
        #expect(section.contains("Text(forcedSolidReason.explanation)"))
        let theme = try Self.source("Sources/RafuApp/Settings/ThemeSettingsSection.swift")
        #expect(theme.contains("WindowSurfaceSettingsSection()"))
        let app = try Self.source("Sources/RafuApp/App/RafuApp.swift")
        #expect(app.contains("WindowSurfacePreference.migrateFrostSpike(defaults: .standard)"))
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
            directory.deleteLastPathComponent()
        }
        throw SourceError.repositoryRootNotFound
    }

    private enum SourceError: Error {
        case repositoryRootNotFound
    }
}
