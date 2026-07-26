import Foundation
import RafuCore
import Testing

@testable import RafuApp

@Suite("App variant state isolation")
struct AppSupportRootTests {
    @Test("Every app-owned state site resolves below the selected identity root")
    func everyStateSiteUsesIdentityRoot() {
        let base = URL(filePath: "/tmp/rafu-variant-state", directoryHint: .isDirectory)

        for identity in [RafuAppIdentity.release, .lightning] {
            let root = identity.applicationSupportRoot(baseDirectory: base)
            let defaultRoot = identity.applicationSupportRoot()

            #expect(
                LauncherIPCSocketPath.resolve(baseDirectory: base, identity: identity).path
                    == root.appending(path: "ipc/v1.sock").path)
            #expect(
                WorkspaceTrustStore.defaultBaseDirectory(identity: identity).path
                    == defaultRoot.path)
            #expect(
                UserEntryStore.defaultBaseDirectory(identity: identity).path
                    == defaultRoot.path)
            #expect(
                InstallLayout.defaultBaseDirectory(identity: identity).path
                    == defaultRoot.path)
            #expect(
                ConductorDefinitionLibrary.defaultUserLibraryRoot(identity: identity).path
                    == defaultRoot.appending(path: "conductor").path)
            #expect(
                ThemeFileService.themesDirectory(identity: identity).path
                    == defaultRoot.appending(path: "Themes").path)
        }
    }

    @Test("Release and Lightning cannot share a socket or state root")
    func variantsDiffer() {
        let base = URL(filePath: "/tmp/rafu-variant-state", directoryHint: .isDirectory)

        #expect(
            RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base).path
                != RafuAppIdentity.lightning.applicationSupportRoot(baseDirectory: base).path)
        #expect(
            LauncherIPCSocketPath.resolve(baseDirectory: base, identity: .release).path
                != LauncherIPCSocketPath.resolve(baseDirectory: base, identity: .lightning).path)
        #expect(
            RafuAppIdentity.release.keychainService != RafuAppIdentity.lightning.keychainService)
    }

    @Test("No source outside RafuAppIdentity constructs a Rafu state root")
    func sourceGuard() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let sources = root.appending(path: "Sources", directoryHint: .isDirectory)
        let identityFile = root.appending(path: "Sources/RafuCore/RafuAppIdentity.swift").path
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        )
        var violations: [String] = []
        let forbiddenConstructions = [
            #"appending(path: "Rafu"#,
            #"appendingPathComponent("Rafu"#,
            #"Application Support/Rafu"#,
        ]

        for case let file as URL in enumerator
        where file.pathExtension == "swift" && file.path != identityFile {
            let source = try String(contentsOf: file, encoding: .utf8)
            if forbiddenConstructions.contains(where: source.contains) {
                violations.append(file.path.replacingOccurrences(of: root.path + "/", with: ""))
            }
        }

        #expect(
            violations.isEmpty,
            "Rafu-owned Application Support paths must use RafuAppIdentity: \(violations)"
        )
    }
}
