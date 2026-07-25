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
