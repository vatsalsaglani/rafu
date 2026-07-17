import Foundation

nonisolated struct CLIInstallResult: Sendable {
    let installedURL: URL
    let pathHint: String?
}

nonisolated struct CLIInstaller: Sendable {
    /// The bundled CLI to link to. Defaults to the copy shipped inside the
    /// running app bundle; injectable so tests can point at a temporary file.
    let source: URL
    /// Where the `rafu` symlink is created. Defaults to `~/.local/bin`;
    /// injectable so tests never touch the real home directory.
    let binDirectory: URL

    init(
        source: URL = Bundle.main.bundleURL.appending(path: "Contents/SharedSupport/bin/rafu"),
        binDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/bin", directoryHint: .isDirectory)
    ) {
        self.source = source
        self.binDirectory = binDirectory
    }

    /// Installs `rafu` as a **symlink** into `binDirectory` pointing at the
    /// bundled CLI, rather than copying it. The symlink lets
    /// `LauncherAppLocator` resolve back into the enclosing `Rafu.app` (a
    /// plain copy has no bundle above it, so the CLI could never find the app
    /// to open), and it auto-tracks app rebuilds instead of going stale until
    /// the next manual reinstall.
    @concurrent
    func install() async throws -> CLIInstallResult {
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: source.path) else {
            throw CLIInstallerError.missingBundledExecutable
        }

        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let destination = binDirectory.appending(path: "rafu")

        // Replace only something we plausibly own: a symlink from a previous
        // install (detected without following it, so a dangling link left by a
        // since-moved bundle is still cleaned up) or a regular file from the
        // older copy-based installer. Refuse to clobber a directory or
        // anything else.
        let existing = try? destination.resourceValues(
            forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        if existing?.isSymbolicLink == true || existing?.isRegularFile == true {
            try fileManager.removeItem(at: destination)
        } else if fileManager.fileExists(atPath: destination.path) {
            throw CLIInstallerError.destinationIsNotReplaceable(destination.path)
        }

        try fileManager.createSymbolicLink(at: destination, withDestinationURL: source)

        let pathEntries =
            ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        let hint =
            pathEntries.contains(binDirectory.path)
            ? nil
            : "Add export PATH=\"$HOME/.local/bin:$PATH\" to your shell profile."
        return CLIInstallResult(installedURL: destination, pathHint: hint)
    }
}

enum CLIInstallerError: LocalizedError, Equatable {
    case missingBundledExecutable
    case destinationIsNotReplaceable(String)

    var errorDescription: String? {
        switch self {
        case .missingBundledExecutable:
            "The bundled rafu command was not found. Launch Rafu from its staged app bundle."
        case .destinationIsNotReplaceable(let path):
            "Rafu will not replace the non-file item at \(path)."
        }
    }
}
