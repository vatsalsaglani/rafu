import Foundation
import Testing

@testable import RafuApp

@Suite("Release optimizer workarounds")
struct ReleaseOptimizerWorkaroundTests {
    @Test("Generic AppKit bridge destructors remain explicit for Apple Swift 6.3.3")
    func genericAppKitBridgeDestructorsRemainExplicit() throws {
        let hostingViewSource = try Self.source(
            "Sources/RafuApp/Terminal/NotchHUDWindow.swift"
        )
        let splitViewSource = try Self.source(
            "Sources/RafuApp/Terminal/TerminalGroupSplitView.swift"
        )

        #expect(hostingViewSource.contains("NotchHUDPassthroughHostingView"))
        #expect(hostingViewSource.contains("deinit {}"))
        #expect(splitViewSource.contains("final class Coordinator"))
        #expect(splitViewSource.contains("deinit {}"))
    }

    private static func source(_ path: String, file: StaticString = #filePath) throws -> String {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path
            ) {
                return try String(contentsOf: directory.appending(path: path), encoding: .utf8)
            }
            directory = directory.deletingLastPathComponent()
        }
        throw ReleaseOptimizerWorkaroundTestError.repositoryRootNotFound
    }

    private enum ReleaseOptimizerWorkaroundTestError: Error {
        case repositoryRootNotFound
    }
}
