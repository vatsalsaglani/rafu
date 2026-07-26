import AppKit
import CryptoKit
import Foundation
import Testing

@testable import RafuApp

@Test("Branded folder icons resolve to bundled SVG assets")
@MainActor
func brandedFolderIconsResolve() {
    let claude = FileIconProvider.directoryIcon(named: ".claude")
    let codex = FileIconProvider.directoryIcon(named: ".codex")
    let gemini = FileIconProvider.directoryIcon(named: ".gemini")
    #expect(claude.assetName == "claude")
    #expect(codex.assetName == "codex")
    #expect(codex.assetIsTemplate)
    #expect(gemini.assetName == "gemini")

    // The dev fallback path (Resources/FileIcons) must decode via NSImage so
    // rows never silently regress to SF Symbols because an asset went missing.
    for name in ["claude", "codex", "gemini"] {
        #expect(FileIconAssets.image(named: name) != nil, "missing FileIcons/\(name).svg")
    }
}

@MainActor
@Test("Every agent CLI resolves to a normalized, loadable vendored SVG")
func agentCLIIconsResolveExhaustively() throws {
    let expected: [ConductorCLIID: String] = [
        .claudeCode: "agent-claude-code",
        .codex: "agent-codex",
        .openCode: "agent-opencode",
        .cline: "agent-cline",
        .kimi: "agent-kimi",
        .geminiCLI: "agent-gemini",
        .cursor: "agent-cursor",
    ]

    #expect(expected.count == ConductorCLIID.allCases.count)
    for id in ConductorCLIID.allCases {
        let expectedName = try #require(expected[id])
        let icon = ConductorCLIIcons.icon(for: id)
        #expect(icon.assetName == expectedName)
        #expect(icon.assetIsTemplate)
        #expect(icon.symbol == "terminal")
        #expect(FileIconAssets.image(named: expectedName) != nil)

        let data = try Data(contentsOf: fileIconURL(named: expectedName))
        let svg = try #require(String(data: data, encoding: .utf8))
        #expect(svg.contains("fill=\"currentColor\""))
        #expect(!svg.contains("<title"))
        #expect(!svg.contains(" style="))
    }
}

/// UX-03 evidence pin for the NSMenu rendering limitation. The vendored marks
/// are authored `width="1em" height="1em"`, so `NSImage` reports a 1×1-pt
/// intrinsic size. SwiftUI views fix that with `.resizable().frame(_:)` (which
/// is why `FileIconView` is correct in the sheet and the new inline launcher),
/// but SwiftUI `Menu` content is bridged to `NSMenuItem`, which draws its image
/// at the image's OWN size and honors no SwiftUI layout — hence the "tiny dot".
/// An SF Symbol image carries a real size, which is why `Label(_:systemImage:)`
/// survived in the same menu.
@MainActor
@Test("Vendored agent marks have a 1x1 pt intrinsic size that NSMenuItem does not correct")
func vendoredAgentMarksHaveOnePointIntrinsicSizeInMenus() throws {
    for id in ConductorCLIID.allCases {
        let assetName = try #require(ConductorCLIIcons.icon(for: id).assetName)
        let image = try #require(FileIconAssets.image(named: assetName))
        #expect(image.size == NSSize(width: 1, height: 1))

        let item = NSMenuItem(title: id.displayName, action: nil, keyEquivalent: "")
        item.image = image
        #expect(item.image?.size == NSSize(width: 1, height: 1))
    }

    let symbol = try #require(
        NSImage(systemSymbolName: "terminal", accessibilityDescription: nil))
    let symbolItem = NSMenuItem(title: "Terminal", action: nil, keyEquivalent: "")
    symbolItem.image = symbol
    let symbolSize = try #require(symbolItem.image?.size)
    #expect(symbolSize.width > 8 && symbolSize.height > 8)
}

/// UX2-03: the Codex card shows the **OpenAI** mark, not lobe-icons' `codex`
/// slug, because users did not recognise the latter as Codex. The doc's refresh
/// loop still maps `codex → agent-codex.svg`, so a naive re-run would silently
/// revert this product decision — this pin turns that into a failing test.
/// See `docs/references/agent-icon-assets.md`.
@Test("The Codex agent mark is the pinned OpenAI mark")
func codexAgentMarkIsTheOpenAIMark() throws {
    let data = try Data(contentsOf: fileIconURL(named: "agent-codex"))
    let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    #expect(hash == "a4b3229f45f5c7e3b31bf972a4dd5c488518e34c920ae1d0650dcf90d0e8f047")
}

@Test("Existing file-tree vendor icons remain byte-identical")
func existingFileTreeVendorIconsRemainByteIdentical() throws {
    let expectedSHA256 = [
        "claude": "76f284df8f840fa41d202c5bc94de60f69f34e8b4bd2c4b0c99527d738a3003b",
        "codex": "54897ba150a45d473496bd141b1dcb3b3ac74b7dac2ddfab8b41ad0e6fba8315",
        "gemini": "1b0ff9d938ee8df5c761c088eba9e38b9a631e0f73fa025cd9c9acfb737c3545",
    ]

    for (name, expectedHash) in expectedSHA256 {
        let data = try Data(contentsOf: fileIconURL(named: name))
        let actualHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(actualHash == expectedHash)
    }
}

private func fileIconURL(named name: String) -> URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "Resources/FileIcons/\(name).svg", directoryHint: .notDirectory)
}
