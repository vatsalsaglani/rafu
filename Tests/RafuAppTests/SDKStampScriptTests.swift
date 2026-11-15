import Foundation
import Testing

/// The staged bundle must record the real SDK in `LC_BUILD_VERSION`, not the
/// deployment target. These tests cover the script-level pieces; the bundle
/// itself is checked by `script/build_and_run.sh` through
/// `script/check_sdk_stamp.sh`.
@Suite("SDK stamp scripts")
struct SDKStampScriptTests {
    @Test("check_sdk_stamp.sh passes its fixture self-test")
    func checkerSelfTest() throws {
        let script = try Self.repositoryRoot().appending(path: "script/check_sdk_stamp.sh")
        let process = Process()
        process.executableURL = script
        process.arguments = ["--self-test"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "\(text)")
    }

    @Test("sdk_link_flags.sh pairs the declared minimum with the computed SDK")
    func linkFlags() throws {
        let script = try Self.repositoryRoot().appending(path: "script/sdk_link_flags.sh")
        let process = Process()
        process.executableURL = script
        process.arguments = ["15.0"]
        process.environment = ["RAFU_SDK_VERSION": "26.2", "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let text = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                == "-Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker 26.2")
    }

    @Test("build_and_run.sh minimum OS matches Package.swift and stamps every product")
    func buildScriptContract() throws {
        let root = try Self.repositoryRoot()
        let script = try String(
            contentsOf: root.appending(path: "script/build_and_run.sh"), encoding: .utf8)
        let manifest = try String(
            contentsOf: root.appending(path: "Package.swift"), encoding: .utf8)
        #expect(script.contains(#"MIN_SYSTEM_VERSION="15.0""#))
        #expect(manifest.contains(".macOS(.v15)"))
        for product in ["GUI_PRODUCT", "CLI_PRODUCT", "HOOK_HELPER_PRODUCT", "WIDGET_PRODUCT"] {
            #expect(
                script.contains(#"swift build --product "$\#(product)" "${SDK_LINK_FLAGS[@]}""#),
                "\(product) is built without the SDK link flags")
        }
        #expect(script.contains("check_sdk_stamp.sh"))
    }

    private static func repositoryRoot(file: StaticString = #filePath) throws -> URL {
        var directory = URL(fileURLWithPath: "\(file)").deletingLastPathComponent()
        while directory.path != "/" {
            if FileManager.default.fileExists(
                atPath: directory.appending(path: "Package.swift").path)
            {
                return directory
            }
            directory = directory.deletingLastPathComponent()
        }
        throw RepositoryRootError.notFound
    }

    private enum RepositoryRootError: Error { case notFound }
}
