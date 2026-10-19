import Foundation
import Testing

@testable import RafuApp

/// `WorkspaceSession.newOrdinaryShellLaunchProfile(shell:)` — the launch
/// profile an Ensemble terminal card uses (terminal-manager.md T-C), shared
/// with `newTerminalGroup(shell:)`'s existing behavior.
@Suite("Ensemble terminal card shell launch profile")
@MainActor
struct WorkspaceSessionShellLaunchProfileTests {
    // A made-up path: never a real shell, so recording it as the preferred
    // shell below cannot collide with, and persist as, a real one.
    private let fixtureShell = TerminalShell(
        path: "/opt/rafu-fixture-shells/fish", name: "fish", isDefault: false)

    @Test("A chosen shell becomes the profile's approved path")
    func chosenShellBecomesApprovedPath() {
        let session = WorkspaceSession()

        let profile = session.newOrdinaryShellLaunchProfile(shell: fixtureShell)

        #expect(profile.shell == .approvedShellPath(fixtureShell.path))
        #expect(profile.startingFolder == .root)
    }

    @Test("No shell resolves to a concrete path or the preferred-shell choice, never garbage")
    func noShellResolvesToAConcreteChoice() {
        let session = WorkspaceSession()

        let profile = session.newOrdinaryShellLaunchProfile(shell: nil)

        switch profile.shell {
        case .preferredShell:
            break
        case .approvedShellPath(let path):
            #expect(!path.isEmpty)
        }
        #expect(profile.startingFolder == .root)
    }
}
