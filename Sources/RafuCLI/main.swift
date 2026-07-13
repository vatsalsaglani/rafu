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

    case .status, .listSSHHosts, .open:
        writeError(
            "The Rafu CLI request was valid, but app IPC is not implemented in the pre-initial-push workbench. See docs/plans/phases/phase-0-feasibility.md."
        )
        exit(EX_UNAVAILABLE)
    }
} catch {
    writeError("rafu: \(error.localizedDescription)")
    writeError("Run 'rafu --help' for usage.")
    exit(EX_USAGE)
}
