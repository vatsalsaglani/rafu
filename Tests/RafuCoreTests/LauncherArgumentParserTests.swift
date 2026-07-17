import Foundation
import RafuCore
import Testing

@Suite("Launcher argument parser")
struct LauncherArgumentParserTests {
    private let parser = LauncherArgumentParser()

    @Test("No arguments show help")
    func noArgumentsShowHelp() throws {
        #expect(try parser.parse([]) == .help)
    }

    @Test("Version flag")
    func versionFlag() throws {
        #expect(try parser.parse(["--version"]) == .version)
    }

    @Test("Local workspace request")
    func localWorkspaceRequest() throws {
        let invocation = try parser.parse(["--new-window", "--wait", "."])
        let expected = LauncherInvocation.open(
            LauncherOpenRequest(
                target: .local(path: "."),
                activationPolicy: .newWindow,
                wait: true
            )
        )

        #expect(invocation == expected)
    }

    @Test("SSH source location request")
    func sshSourceLocationRequest() throws {
        let invocation = try parser.parse([
            "--ssh", "prod-api",
            "--goto", "/srv/api/Sources/main.py:42:8",
        ])
        let expected = LauncherInvocation.open(
            LauncherOpenRequest(
                target: .ssh(hostAlias: "prod-api", path: "/srv/api/Sources/main.py"),
                sourceLocation: SourceLocation(line: 42, column: 8)
            )
        )

        #expect(invocation == expected)
    }

    @Test("Window policy flags conflict")
    func windowPolicyFlagsConflict() {
        #expect(throws: LauncherArgumentError.conflictingWindowPolicies) {
            try parser.parse(["--new-window", "--reuse-window", "."])
        }
    }

    @Test("SSH option cannot consume another option as its value")
    func sshOptionRequiresAValue() {
        #expect(throws: LauncherArgumentError.missingValue("--ssh")) {
            try parser.parse(["--ssh", "--wait"])
        }
    }

    @Test("Goto option cannot consume another option as its value")
    func gotoOptionRequiresAValue() {
        #expect(throws: LauncherArgumentError.missingValue("--goto")) {
            try parser.parse(["--goto", "--new-window"])
        }
    }
}

@Test("App locator resolves the bundle enclosing the bundled CLI")
func appLocatorResolvesBundle() {
    let cli = URL(fileURLWithPath: "/Users/x/dist/Rafu.app/Contents/SharedSupport/bin/rafu")
    let bundle = LauncherAppLocator.appBundle(forCLIExecutable: cli, requireOnDisk: false)
    #expect(bundle?.path == "/Users/x/dist/Rafu.app")

    let stray = URL(fileURLWithPath: "/usr/local/bin/rafu")
    #expect(LauncherAppLocator.appBundle(forCLIExecutable: stray, requireOnDisk: false) == nil)
}

@Test("enclosingAppBundle follows a ~/.local/bin symlink back into the bundle")
func enclosingAppBundleFollowsInstalledSymlink() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
        path: "rafu-locator-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? fileManager.removeItem(at: root) }

    // A real Rafu.app tree with the bundled CLI, and a marker under
    // Contents/MacOS so the on-disk check passes.
    let bundledCLI = root.appending(path: "Rafu.app/Contents/SharedSupport/bin/rafu")
    try fileManager.createDirectory(
        at: bundledCLI.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: bundledCLI)
    try fileManager.createDirectory(
        at: root.appending(path: "Rafu.app/Contents/MacOS"), withIntermediateDirectories: true)

    // The installer-style symlink at a location with no bundle above it.
    let binDirectory = root.appending(path: ".local/bin")
    try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
    let symlink = binDirectory.appending(path: "rafu")
    try fileManager.createSymbolicLink(at: symlink, withDestinationURL: bundledCLI)

    // Resolving the symlink lands back inside Rafu.app; the raw symlink path
    // (no bundle above ~/.local/bin) would not — this is what the real-exec-
    // path locator relies on for a PATH-installed CLI.
    let resolved = LauncherAppLocator.enclosingAppBundle(executablePath: symlink.path)
    // Normalize both sides: the temp dir lives under /var/folders which
    // `resolvingSymlinksInPath()` rewrites to /private/var.
    let expectedBundle = root.appending(path: "Rafu.app").resolvingSymlinksInPath()
        .standardizedFileURL.path
    #expect(resolved?.standardizedFileURL.path == expectedBundle)

    let unresolved = LauncherAppLocator.appBundle(forCLIExecutable: symlink)
    #expect(unresolved == nil)
}
