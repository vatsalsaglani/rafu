import Foundation
import Testing

@testable import RafuApp

@Suite("CLI installer")
struct CLIInstallerTests {
    /// Writes an executable stand-in for the bundled `rafu` under a fake
    /// `Rafu.app/Contents/SharedSupport/bin/` tree and returns its URL.
    private func makeBundledCLI(in root: URL) throws -> URL {
        let source = root.appending(path: "Rafu.app/Contents/SharedSupport/bin/rafu")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: source.path)
        return source
    }

    @Test("Installs rafu as a symlink pointing at the bundled CLI")
    func installsSymlink() async throws {
        try await withTemporaryDirectory { root in
            let source = try makeBundledCLI(in: root)
            let binDirectory = root.appending(path: "bin")

            let result = try await CLIInstaller(source: source, binDirectory: binDirectory)
                .install()

            let destination = binDirectory.appending(path: "rafu")
            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            #expect(values.isSymbolicLink == true)
            #expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
                    == source.path)
            #expect(result.installedURL.path == destination.path)
            // The symlink is executable (via its target) — the whole point.
            #expect(FileManager.default.isExecutableFile(atPath: destination.path))
        }
    }

    @Test("Replaces a stale regular-file copy left by the older copy-based installer")
    func replacesRegularFileCopy() async throws {
        try await withTemporaryDirectory { root in
            let source = try makeBundledCLI(in: root)
            let binDirectory = root.appending(path: "bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true)
            let destination = binDirectory.appending(path: "rafu")
            try Data("stale copy".utf8).write(to: destination)

            _ = try await CLIInstaller(source: source, binDirectory: binDirectory).install()

            let values = try destination.resourceValues(forKeys: [.isSymbolicLinkKey])
            #expect(values.isSymbolicLink == true)
            #expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
                    == source.path)
        }
    }

    @Test("Replaces a dangling symlink from a since-moved bundle")
    func replacesDanglingSymlink() async throws {
        try await withTemporaryDirectory { root in
            let source = try makeBundledCLI(in: root)
            let binDirectory = root.appending(path: "bin")
            try FileManager.default.createDirectory(
                at: binDirectory, withIntermediateDirectories: true)
            let destination = binDirectory.appending(path: "rafu")
            // A link to a path that does not exist — `fileExists` follows it and
            // reports false, so the installer must detect the link itself.
            try FileManager.default.createSymbolicLink(
                atPath: destination.path,
                withDestinationPath: root.appending(path: "gone/rafu").path)

            _ = try await CLIInstaller(source: source, binDirectory: binDirectory).install()

            #expect(
                try FileManager.default.destinationOfSymbolicLink(atPath: destination.path)
                    == source.path)
        }
    }

    @Test("Refuses to replace a directory at the destination")
    func refusesDirectory() async throws {
        try await withTemporaryDirectory { root in
            let source = try makeBundledCLI(in: root)
            let binDirectory = root.appending(path: "bin")
            let destination = binDirectory.appending(path: "rafu")
            try FileManager.default.createDirectory(
                at: destination, withIntermediateDirectories: true)

            await #expect(throws: CLIInstallerError.self) {
                try await CLIInstaller(source: source, binDirectory: binDirectory).install()
            }
            // The directory is left untouched.
            var isDirectory: ObjCBool = false
            #expect(
                FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory)
                    && isDirectory.boolValue)
        }
    }

    @Test("Throws when the bundled CLI is missing")
    func missingBundledExecutable() async throws {
        try await withTemporaryDirectory { root in
            let installer = CLIInstaller(
                source: root.appending(path: "does-not-exist/rafu"),
                binDirectory: root.appending(path: "bin"))
            await #expect(throws: CLIInstallerError.missingBundledExecutable) {
                try await installer.install()
            }
        }
    }
}
