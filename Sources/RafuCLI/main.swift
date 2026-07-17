import Darwin
import Foundation
import RafuCore

private func writeError(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private func runOpen(bundleURL: URL, documentURL: URL?) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = ["-a", bundleURL.path] + (documentURL.map { [$0.path] } ?? [])
    try process.run()
    process.waitUntilExit()
    return process.terminationStatus
}

private func normalizedLocalRequest(
    _ request: LauncherOpenRequest,
    path: String
) -> (request: LauncherOpenRequest, fallbackFolder: URL)? {
    let targetURL = URL(fileURLWithPath: path).standardizedFileURL
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory)
    else { return nil }

    let fallbackFolder: URL
    if request.sourceLocation != nil {
        guard !isDirectory.boolValue else { return nil }
        fallbackFolder = targetURL.deletingLastPathComponent()
    } else {
        guard isDirectory.boolValue else { return nil }
        fallbackFolder = targetURL
    }

    return (
        LauncherOpenRequest(
            target: .local(path: targetURL.path),
            sourceLocation: request.sourceLocation,
            activationPolicy: request.activationPolicy,
            wait: request.wait
        ),
        fallbackFolder
    )
}

private func coldStartRequest(_ request: LauncherOpenRequest) -> LauncherOpenRequest {
    guard request.activationPolicy == .automatic else { return request }
    return LauncherOpenRequest(
        target: request.target,
        sourceLocation: request.sourceLocation,
        activationPolicy: .newWindow,
        wait: request.wait
    )
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
            guard let normalized = normalizedLocalRequest(request, path: path) else {
                let expected = request.sourceLocation == nil ? "directory" : "file"
                writeError("rafu: '\(path)' is not a readable \(expected).")
                exit(EX_NOINPUT)
            }

            let client = LauncherIPCClient()
            var response: LauncherIPCResponse?
            var lastError: Error?
            do {
                response = try client.perform(normalized.request)
            } catch {
                lastError = error
            }

            var bundleURL: URL?
            if response == nil,
                let clientError = lastError as? LauncherIPCClientError,
                clientError.isListenerUnavailable
            {
                bundleURL = LauncherAppLocator.enclosingAppBundle()
                if let bundleURL {
                    do {
                        let status = try runOpen(bundleURL: bundleURL, documentURL: nil)
                        if status == 0 {
                            let request = coldStartRequest(normalized.request)
                            for delay in [useconds_t(0)]
                                + LauncherIPCReconnectSchedule.delaysMicroseconds
                            {
                                if delay > 0 { usleep(delay) }
                                do {
                                    response = try client.perform(request)
                                    lastError = nil
                                    break
                                } catch {
                                    lastError = error
                                }
                            }
                        } else {
                            lastError = LauncherIPCClientError.systemCall(
                                name: "open-starter", code: status)
                        }
                    } catch {
                        lastError = error
                    }
                }
            }

            if let response {
                switch response {
                case .accepted(_, _, let waitSupported):
                    print("Opening \(path) in \(RafuBuildInformation.appName).")
                    if normalized.request.wait, !waitSupported {
                        writeError(
                            "rafu: --wait is not yet available; the request was opened without waiting."
                        )
                    }
                case .rejected(let reason):
                    writeError("rafu: Rafu.app rejected the request: \(reason)")
                    exit(EX_UNAVAILABLE)
                }
                break
            }

            if bundleURL == nil {
                bundleURL = LauncherAppLocator.enclosingAppBundle()
            }
            guard let bundleURL else {
                writeError(
                    "rafu: could not locate Rafu.app relative to this CLI. Reinstall the CLI from Rafu's command palette."
                )
                exit(EX_UNAVAILABLE)
            }
            do {
                let status = try runOpen(
                    bundleURL: bundleURL,
                    documentURL: normalized.fallbackFolder
                )
                guard status == 0 else {
                    writeError("rafu: failed to open Rafu.app (open exited \(status)).")
                    exit(EX_UNAVAILABLE)
                }
                print("Opening \(path) in \(RafuBuildInformation.appName) (fallback).")
            } catch {
                if let lastError {
                    writeError("rafu: launcher IPC failed: \(lastError.localizedDescription)")
                }
                writeError("rafu: failed to open Rafu.app: \(error.localizedDescription)")
                exit(EX_UNAVAILABLE)
            }
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
