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
