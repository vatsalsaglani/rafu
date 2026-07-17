import Foundation

/// Resolves an npm-hosted server's own dependencies after its release
/// tarball has been unpacked but before it is moved into place — a bare
/// tarball extraction never bundles `node_modules`. Injected so tests never
/// spawn a real `npm install` — production uses `NpmDependencyResolver`;
/// tests inject a fake that records its arguments and fabricates a small
/// `node_modules/` fixture directory instead.
nonisolated protocol NodeDependencyResolving: Sendable {
    /// Installs `packageDirectory`'s dependencies in place. `packageDirectory`
    /// is the npm package root inside the install's staging directory (e.g.
    /// `<staging>/package`), and `nodeExecutableURL` is the managed Node
    /// runtime's `bin/node` binary. Throws on any non-zero exit; never
    /// silently tolerates a failed resolution — a server without its
    /// dependencies is not a runnable install.
    func installDependencies(packageDirectory: URL, nodeExecutableURL: URL) async throws
}

/// The production resolver: derives npm's own CLI entry point from the
/// managed Node runtime's `bin/node` executable — Node's own layout ships
/// npm at `<runtimeRoot>/lib/node_modules/npm/bin/npm-cli.js`, two directory
/// levels above `bin/node` — and spawns it through `node` itself (npm has no
/// standalone executable of its own to invoke directly).
///
/// `--ignore-scripts` is not a hardening option here, it is mandatory:
/// arbitrary npm packages ship `preinstall`/`postinstall` scripts that would
/// otherwise run with the same privileges as Rafu during every install.
/// `--omit=dev`, `--no-audit`, `--no-fund`, and `--no-package-lock` keep the
/// install to production dependencies only, offline-friendly, and without
/// writing a lockfile Rafu does not own; `--prefer-offline` favors npm's
/// local cache over a network round-trip when the cache already has what is
/// needed. Never logs the resolved paths or argv — a workspace or user
/// entry's install location is not something this type surfaces.
nonisolated struct NpmDependencyResolver: NodeDependencyResolving {
    func installDependencies(packageDirectory: URL, nodeExecutableURL: URL) async throws {
        let runtimeRoot =
            nodeExecutableURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let npmCLI = runtimeRoot.appending(path: "lib/node_modules/npm/bin/npm-cli.js")

        let arguments = [
            npmCLI.path,
            "install",
            "--omit=dev",
            "--no-audit",
            "--no-fund",
            "--ignore-scripts",
            "--no-package-lock",
            "--prefer-offline",
        ]

        let status = try await ArchiveUnpacker.runArgv(
            executableURL: nodeExecutableURL, arguments: arguments,
            currentDirectoryURL: packageDirectory)
        guard status == 0 else { throw ServerInstallError.dependencyResolutionFailed(status) }
    }
}
