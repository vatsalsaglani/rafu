import Foundation
import RafuCore
import Testing

@Suite("Rafu app identity")
struct RafuAppIdentityTests {
    @Test("A release Info.plist resolves the release identity")
    func releaseBundle() throws {
        let fixture = try makeBundleFixture(
            name: "Rafu",
            identifier: RafuAppIdentity.release.bundleIdentifier
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let identity = RafuAppIdentity.resolve(bundle: fixture.bundle)

        #expect(identity == .release)
        #expect(identity.displayName == "Rafu")
        #expect(identity.applicationSupportDirectory == "Rafu")
        #expect(!identity.isLightning)
    }

    @Test("A Lightning Info.plist resolves the Lightning identity")
    func lightningBundle() throws {
        let fixture = try makeBundleFixture(
            name: "Rafu Lightning",
            identifier: RafuAppIdentity.lightning.bundleIdentifier
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let identity = RafuAppIdentity.resolve(bundle: fixture.bundle)

        #expect(identity == .lightning)
        #expect(identity.displayName == "Rafu Lightning")
        #expect(identity.applicationSupportDirectory == "Rafu Lightning")
        #expect(identity.isLightning)
    }

    @Test("No or unknown bundle falls back to release, never Lightning")
    func safeFallback() throws {
        #expect(RafuAppIdentity.resolve(bundle: nil) == .release)

        let fixture = try makeBundleFixture(
            name: "Unknown",
            identifier: "dev.example.unknown"
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(RafuAppIdentity.resolve(bundle: fixture.bundle) == .release)
    }

    @Test("State, Keychain, executable, CLI, and seam values derive from identity")
    func derivedValues() {
        let base = URL(fileURLWithPath: "/tmp/rafu-app-identity")

        #expect(
            RafuAppIdentity.release.applicationSupportRoot(baseDirectory: base).path
                == "/tmp/rafu-app-identity/Rafu")
        #expect(
            RafuAppIdentity.lightning.applicationSupportRoot(baseDirectory: base).path
                == "/tmp/rafu-app-identity/Rafu Lightning")
        #expect(RafuAppIdentity.release.keychainService == "dev.vatsalsaglani.rafu.ai-provider-key")
        #expect(
            RafuAppIdentity.lightning.keychainService
                == "dev.vatsalsaglani.rafu.lightning.ai-provider-key")
        #expect(RafuAppIdentity.release.executableName == "Rafu")
        #expect(RafuAppIdentity.lightning.executableName == "RafuLightning")
        #expect(RafuAppIdentity.release.cliName == "rafu")
        #expect(RafuAppIdentity.lightning.cliName == "rafu-lightning")
        #expect(RafuAppIdentity.release.seamColorHex == "#E3A857")
        #expect(RafuAppIdentity.lightning.seamColorHex == "#C0C6CE")
    }
}

private struct BundleFixture {
    let root: URL
    let bundle: Bundle
}

private func makeBundleFixture(name: String, identifier: String) throws -> BundleFixture {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
        path: "rafu-identity-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    let bundleURL = root.appending(path: "\(name).app", directoryHint: .isDirectory)
    let contents = bundleURL.appending(path: "Contents", directoryHint: .isDirectory)
    let executableDirectory = contents.appending(path: "MacOS", directoryHint: .isDirectory)
    try fileManager.createDirectory(at: executableDirectory, withIntermediateDirectories: true)

    let executableName = name.replacingOccurrences(of: " ", with: "")
    let executable = executableDirectory.appending(path: executableName)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

    let info: [String: Any] = [
        "CFBundleExecutable": executableName,
        "CFBundleIdentifier": identifier,
        "CFBundleName": name,
        "CFBundlePackageType": "APPL",
    ]
    let plist = try PropertyListSerialization.data(
        fromPropertyList: info,
        format: .xml,
        options: 0
    )
    try plist.write(to: contents.appending(path: "Info.plist"), options: .atomic)
    return BundleFixture(root: root, bundle: try #require(Bundle(url: bundleURL)))
}
