import Foundation
import Testing

@testable import RafuApp

private func actionWorkflow(
    at url: URL,
    stem: String = "review"
) -> ConductorLibraryWorkflow {
    ConductorLibraryWorkflow(
        fileURL: url,
        stem: stem,
        scope: .repository,
        resolution: .selected,
        definition: ConductorWorkflowDefinition(
            name: "Review",
            steps: [
                .init(agentName: "Reviewer", inputArtifacts: [], gateAfter: false)
            ]),
        issues: [])
}

@Test("Duplicate creates stable unique workflow files without overwriting")
func duplicateWorkflowCreatesUniqueFiles() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "rafu-library-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let source = directory.appending(path: "review.md")
    let sourceData = Data("---\nname: Review\nsteps:\n  - Reviewer\n---\n".utf8)
    try sourceData.write(to: source, options: .atomic)
    let workflow = actionWorkflow(at: source)
    let duplicator = ConductorWorkflowFileDuplicator()

    let first = try await duplicator.duplicate(workflow)
    let second = try await duplicator.duplicate(workflow)

    #expect(first.lastPathComponent == "review-copy.md")
    #expect(second.lastPathComponent == "review-copy-2.md")
    #expect(try Data(contentsOf: source) == sourceData)
    #expect(try Data(contentsOf: first) == sourceData)
    #expect(try Data(contentsOf: second) == sourceData)
}

@Test("Duplicate refuses a symlinked workflow source")
func duplicateWorkflowRefusesSymlink() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "rafu-library-actions-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let target = directory.appending(path: "target.md")
    let link = directory.appending(path: "review.md")
    try Data("---\nname: Review\nsteps:\n  - Reviewer\n---\n".utf8)
        .write(to: target)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

    await #expect(throws: ConductorWorkflowFileActionError.unsafeSource) {
        _ = try await ConductorWorkflowFileDuplicator().duplicate(actionWorkflow(at: link))
    }
}
