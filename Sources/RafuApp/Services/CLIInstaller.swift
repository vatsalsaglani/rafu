import Foundation

nonisolated struct CLIInstallResult: Sendable {
    let installedURL: URL
    let pathHint: String?
}

nonisolated struct CLIInstaller: Sendable {
    @concurrent
    func install() async throws -> CLIInstallResult {
        let fileManager = FileManager.default
        let source = Bundle.main.bundleURL
            .appending(path: "Contents/SharedSupport/bin/rafu")
        guard fileManager.isExecutableFile(atPath: source.path) else {
            throw CLIInstallerError.missingBundledExecutable
        }

        let directory = fileManager.homeDirectoryForCurrentUser
            .appending(path: ".local/bin", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "rafu")
        let temporary = directory.appending(path: ".rafu-install-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: temporary) }

        if fileManager.fileExists(atPath: destination.path) {
            let values = try destination.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else {
                throw CLIInstallerError.destinationIsNotReplaceable(destination.path)
            }
            try fileManager.removeItem(at: destination)
        }

        try fileManager.copyItem(at: source, to: temporary)
        try fileManager.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: temporary.path
        )
        try fileManager.moveItem(at: temporary, to: destination)

        let pathEntries =
            ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        let hint =
            pathEntries.contains(directory.path)
            ? nil
            : "Add export PATH=\"$HOME/.local/bin:$PATH\" to your shell profile."
        return CLIInstallResult(installedURL: destination, pathHint: hint)
    }
}

enum CLIInstallerError: LocalizedError {
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
