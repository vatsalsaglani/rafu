import Foundation

nonisolated struct GitCommandOutput: Sendable {
    let arguments: [String]
    let terminationStatus: Int32
    let standardOutput: Data
    let standardError: Data

    var stdout: String { String(decoding: standardOutput, as: UTF8.self) }
    var stderr: String { String(decoding: standardError, as: UTF8.self) }
}

nonisolated struct GitCommandRunner: Sendable {
    private let executableURL = URL(fileURLWithPath: "/usr/bin/git")

    @concurrent
    func run(
        arguments: [String],
        at directoryURL: URL,
        standardInput: Data? = nil,
        maximumOutputBytes: Int = 64 * 1_024 * 1_024
    ) async throws -> GitCommandOutput {
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let captureDirectory = fileManager.temporaryDirectory.appending(
            path: "rafu-git-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: captureDirectory) }

        let outputURL = captureDirectory.appending(path: "stdout")
        let errorURL = captureDirectory.appending(path: "stderr")
        guard fileManager.createFile(atPath: outputURL.path, contents: nil),
            fileManager.createFile(atPath: errorURL.path, contents: nil)
        else {
            throw GitServiceError.captureCreationFailed
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        defer {
            try? outputHandle.close()
            try? errorHandle.close()
        }

        // Bounded git invocations that need many pathspecs (batch staging) write
        // them to a temp file and stream it as stdin instead of growing argv,
        // which keeps the exec argument list small and avoids leading-dash /
        // pathspec-magic argv parsing entirely.
        var inputHandle: FileHandle?
        if let standardInput {
            let inputURL = captureDirectory.appending(path: "stdin")
            try standardInput.write(to: inputURL)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        }
        defer { try? inputHandle?.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.currentDirectoryURL = directoryURL
        process.standardInput = inputHandle ?? FileHandle.nullDevice
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.environment = environment()

        do {
            try process.run()
        } catch {
            throw GitServiceError.couldNotLaunch(error.localizedDescription)
        }

        do {
            while process.isRunning {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
        } catch is CancellationError {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw CancellationError()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }

        try outputHandle.close()
        try errorHandle.close()
        try Task.checkCancellation()

        let stdoutSize = try fileSize(at: outputURL)
        let stderrSize = try fileSize(at: errorURL)
        guard stdoutSize <= maximumOutputBytes, stderrSize <= maximumOutputBytes else {
            throw GitServiceError.outputTooLarge(limit: maximumOutputBytes)
        }

        return try GitCommandOutput(
            arguments: arguments,
            terminationStatus: process.terminationStatus,
            standardOutput: Data(contentsOf: outputURL, options: .mappedIfSafe),
            standardError: Data(contentsOf: errorURL, options: .mappedIfSafe)
        )
    }

    private func environment() -> [String: String] {
        var values = ProcessInfo.processInfo.environment
        values["GIT_TERMINAL_PROMPT"] = "0"
        values["GIT_PAGER"] = "cat"
        values["GIT_EDITOR"] = "true"
        values["GIT_MERGE_AUTOEDIT"] = "no"
        values["LC_ALL"] = "C"
        return values
    }

    private func fileSize(at url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }
}
