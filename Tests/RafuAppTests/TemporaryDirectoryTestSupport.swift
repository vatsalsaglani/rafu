import Foundation

/// Creates a fresh temporary directory, hands it to `body`, and removes it
/// afterward regardless of outcome. Used by every Registry test that needs
/// an injectable Application-Support-style base directory, so none of them
/// ever touch the real `~/Library/Application Support`.
func withTemporaryDirectory<T>(
    _ body: (URL) async throws -> T
) async throws -> T {
    let directory = FileManager.default.temporaryDirectory.appending(
        path: "rafu-registry-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try await body(directory)
}
