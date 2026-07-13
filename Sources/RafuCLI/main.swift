import Darwin
import Foundation
import RafuCore

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

do {
    let invocation = try LauncherArgumentParser().parse(Array(CommandLine.arguments.dropFirst()))

    switch invocation {
    case .help:
        print(LauncherHelp.text)

    case .version:
        print("\(RafuBuildInformation.appName) \(RafuBuildInformation.version)")

    case .open(let request):
        switch request.target {
        case .ssh:
            writeError("rafu: SSH workspaces are not available yet.")
            exit(EX_UNAVAILABLE)
        case .local(let path):
            let folderURL = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(
                    atPath: folderURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else {
                writeError("rafu: '\(path)' is not a directory.")
                exit(EX_NOINPUT)
            }
            guard let bundleURL = LauncherAppLocator.enclosingAppBundle() else {
                writeError(
                    "rafu: could not locate Rafu.app relative to this CLI. Reinstall the CLI from Rafu's command palette."
                )
                exit(EX_UNAVAILABLE)
            }
            let openProcess = Process()
            openProcess.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            openProcess.arguments = ["-a", bundleURL.path, folderURL.path]
            try openProcess.run()
            openProcess.waitUntilExit()
            guard openProcess.terminationStatus == 0 else {
                writeError(
                    "rafu: failed to open Rafu.app (open exited \(openProcess.terminationStatus)).")
                exit(EX_UNAVAILABLE)
            }
            print("Opening \(folderURL.path) in \(RafuBuildInformation.appName).")
        }

    case .status, .listSSHHosts:
        writeError(
            "The Rafu CLI request was valid, but this command is not implemented in the pre-initial-push workbench. See docs/plans/phases/phase-0-feasibility.md."
        )
        exit(EX_UNAVAILABLE)
    }
} catch {
    writeError("rafu: \(error.localizedDescription)")
    writeError("Run 'rafu --help' for usage.")
    exit(EX_USAGE)
}
