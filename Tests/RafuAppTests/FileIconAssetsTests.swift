import AppKit
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
