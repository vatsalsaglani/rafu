import Foundation
import Testing

@testable import RafuApp

@Suite("GitHub CLI parsing")
struct GitHubCLIParsingTests {
    // MARK: - parseAccount

    @Test("A full gh api user response parses login, name, and avatar URL")
    func parseAccountFull() throws {
        let json = """
            {"login":"octocat","name":"The Octocat","avatar_url":"https://example.com/avatar.png"}
            """
        let account = try GitHubCLIService.parseAccount(Data(json.utf8))
        #expect(account.login == "octocat")
        #expect(account.name == "The Octocat")
        #expect(account.avatarURL == URL(string: "https://example.com/avatar.png"))
    }

    @Test("A partial response with only login parses with nil name and avatar")
    func parseAccountPartial() throws {
        let json = #"{"login":"octocat"}"#
        let account = try GitHubCLIService.parseAccount(Data(json.utf8))
        #expect(account.login == "octocat")
        #expect(account.name == nil)
        #expect(account.avatarURL == nil)
    }

    @Test("Malformed JSON throws malformedResponse rather than crashing")
    func parseAccountMalformedJSON() {
        #expect(throws: GitHubCLIError.malformedResponse) {
            try GitHubCLIService.parseAccount(Data("not json".utf8))
        }
    }

    @Test("An empty login throws malformedResponse")
    func parseAccountEmptyLogin() {
        #expect(throws: GitHubCLIError.malformedResponse) {
            try GitHubCLIService.parseAccount(Data(#"{"login":""}"#.utf8))
        }
    }

    @Test("JSON missing the required login field throws malformedResponse")
    func parseAccountMissingLogin() {
        #expect(throws: GitHubCLIError.malformedResponse) {
            try GitHubCLIService.parseAccount(Data(#"{"name":"No Login"}"#.utf8))
        }
    }

    @Test("An unreasonably large response throws malformedResponse without decoding")
    func parseAccountOversized() {
        let oversized = Data(count: 2 * 1_024 * 1_024)
        #expect(throws: GitHubCLIError.malformedResponse) {
            try GitHubCLIService.parseAccount(oversized)
        }
    }

    // MARK: - GitHubCLILocator ordering

    @Test("The first executable fixed candidate wins, in listed order")
    func locatorFixedCandidateOrdering() async throws {
        try await withTemporaryDirectory { directory in
            let first = directory.appending(path: "first-gh")
            let second = directory.appending(path: "second-gh")
            try installExecutable(at: first)
            try installExecutable(at: second)

            let located = GitHubCLILocator.locate(
                fixedCandidates: [first.path, second.path],
                environment: [:],
                fileManager: .default
            )
            #expect(located == first)
        }
    }

    @Test("A missing fixed candidate is skipped in favor of the next one")
    func locatorSkipsMissingFixedCandidate() async throws {
        try await withTemporaryDirectory { directory in
            let missing = directory.appending(path: "missing-gh")
            let present = directory.appending(path: "present-gh")
            try installExecutable(at: present)

            let located = GitHubCLILocator.locate(
                fixedCandidates: [missing.path, present.path],
                environment: [:],
                fileManager: .default
            )
            #expect(located == present)
        }
    }

    @Test("PATH is searched, in order, only after every fixed candidate misses")
    func locatorFallsBackToPATH() async throws {
        try await withTemporaryDirectory { directory in
            let firstDirectory = directory.appending(path: "bin1", directoryHint: .isDirectory)
            let secondDirectory = directory.appending(path: "bin2", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: firstDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: secondDirectory, withIntermediateDirectories: true)
            let secondGH = secondDirectory.appending(path: "gh")
            try installExecutable(at: secondGH)

            let located = GitHubCLILocator.locate(
                fixedCandidates: [],
                environment: ["PATH": "\(firstDirectory.path):\(secondDirectory.path)"],
                fileManager: .default
            )
            #expect(located == secondGH)
        }
    }

    @Test("No candidate anywhere returns nil")
    func locatorReturnsNilWhenNothingFound() async throws {
        try await withTemporaryDirectory { directory in
            let located = GitHubCLILocator.locate(
                fixedCandidates: [directory.appending(path: "nope").path],
                environment: ["PATH": directory.path],
                fileManager: .default
            )
            #expect(located == nil)
        }
    }

    // MARK: - publishArguments

    @Test("publishArguments builds the exact expected argv for a private repository")
    func publishArgumentsPrivate() {
        let arguments = GitHubCLIService.publishArguments(name: "my-repo", visibility: .private)
        #expect(
            arguments == [
                "repo", "create", "my-repo",
                "--source", ".",
                "--private",
                "--remote", "origin",
                "--push",
            ])
    }

    @Test("publishArguments builds the exact expected argv for a public repository")
    func publishArgumentsPublic() {
        let arguments = GitHubCLIService.publishArguments(name: "my-repo", visibility: .public)
        #expect(
            arguments == [
                "repo", "create", "my-repo",
                "--source", ".",
                "--public",
                "--remote", "origin",
                "--push",
            ])
    }

    // MARK: - Repository name validation

    @Test("A well-formed repository name validates")
    func validRepositoryName() throws {
        try GitHubCLIService.validateRepositoryName("my-repo_1.0")
    }

    @Test(
        "Empty, leading-dash, whitespace, and oversized names are all rejected",
        arguments: [
            "", "-leading-dash", "has space", "has\ttab", "has\nnewline",
            String(repeating: "a", count: 101),
        ]
    )
    func invalidRepositoryNames(name: String) {
        #expect(throws: GitHubCLIError.self) {
            try GitHubCLIService.validateRepositoryName(name)
        }
    }

    @Test("A name at exactly the 100-byte limit validates")
    func repositoryNameAtLimit() throws {
        try GitHubCLIService.validateRepositoryName(String(repeating: "a", count: 100))
    }

    // MARK: - Error mapping from representative stderr

    @Test("Not-authenticated stderr maps to notAuthenticated")
    func mapsNotAuthenticated() {
        let error = GitHubCLIService.mapError(
            stderr: "To get started with GitHub CLI, please run: gh auth login",
            terminationStatus: 1
        )
        #expect(error == .notAuthenticated)
    }

    @Test("An already-exists remote error maps to remoteAlreadyExists")
    func mapsRemoteAlreadyExists() {
        let error = GitHubCLIService.mapError(
            stderr: "X remote origin already exists.",
            terminationStatus: 1
        )
        #expect(error == .remoteAlreadyExists)
    }

    @Test("An unrecognized stderr message maps to commandFailed with the trimmed message")
    func mapsGenericCommandFailure() {
        let error = GitHubCLIService.mapError(
            stderr: "  some other gh failure  \n",
            terminationStatus: 1
        )
        #expect(error == .commandFailed("some other gh failure"))
    }

    @Test("Empty stderr falls back to a status-coded generic message")
    func mapsEmptyStderrToGenericMessage() {
        let error = GitHubCLIService.mapError(stderr: "", terminationStatus: 7)
        #expect(error == .commandFailed("GitHub CLI command failed (7)."))
    }
}

private func installExecutable(at url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}
