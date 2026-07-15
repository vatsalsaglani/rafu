import Foundation

/// Pure path math mirroring `NodeRuntimeManager`'s own (private) installed
/// executable location, so `LanguageIntelligenceCoordinator` can check
/// whether the pinned Node runtime is *already* installed without ever
/// triggering an install itself. Only an explicit, consent-gated
/// `NodeRuntimeManager.ensureInstalled(consentToQuarantineRemoval:)` call —
/// reached from the Settings catalog — downloads anything. Never edits
/// `NodeRuntimeManager.swift` itself (owned by lane 2's C3 increment).
nonisolated enum NodeRuntimeLocator {
    static func installedExecutableURL(layout: InstallLayout) -> URL? {
        let url =
            layout.runtimesRoot
            .appending(
                path: "node-\(NodeRuntimeManager.pinnedVersion)", directoryHint: .isDirectory
            )
            .appending(path: "bin/node")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}
