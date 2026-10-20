import Foundation
import Testing

@testable import RafuApp

@Suite("GitHub remote URL")
struct GitHubRemoteURLTests {
    private let sha = "8be02b5fd3f3fc02a1b2c3d4e5f60718293a4b5c"
    private let expected =
        "https://github.com/octo/rafu/commit/8be02b5fd3f3fc02a1b2c3d4e5f60718293a4b5c"

    @Test(
        "Supported GitHub remote forms map to the commit page",
        arguments: [
            "git@github.com:octo/rafu.git",
            "git@github.com:octo/rafu",
            "https://github.com/octo/rafu.git",
            "https://github.com/octo/rafu",
            "https://github.com/octo/rafu/",
            "ssh://git@github.com/octo/rafu.git",
            "ssh://git@github.com:22/octo/rafu.git",
            "  https://GitHub.com/octo/rafu.git\n",
        ])
    func supportedForms(remote: String) {
        #expect(GitHubRemoteURL.commitURL(remote: remote, sha: sha)?.absoluteString == expected)
    }

    @Test("Credentials in an HTTPS remote never reach the commit page")
    func credentialsAreDropped() throws {
        let url = try #require(
            GitHubRemoteURL.commitURL(
                remote: "https://user:ghp_secret@github.com/octo/rafu.git", sha: sha))
        #expect(url.absoluteString == expected)
        #expect(!url.absoluteString.contains("secret"))
        #expect(url.user == nil && url.password == nil)
    }

    @Test(
        "Other hosts and unreadable remotes give no page",
        arguments: [
            "git@gitlab.com:octo/rafu.git",
            "https://example.com/octo/rafu.git",
            "https://github.com.evil.example/octo/rafu.git",
            "https://github.com/octo",
            "https://github.com/octo/rafu/extra",
            "/local/path/repo.git",
            "file:///tmp/repo.git",
            "https://github.com/../rafu.git",
            "",
        ])
    func unsupportedForms(remote: String) {
        #expect(GitHubRemoteURL.commitURL(remote: remote, sha: sha) == nil)
    }

    @Test("A malformed commit ID gives no page")
    func malformedSHA() {
        #expect(
            GitHubRemoteURL.commitURL(remote: "git@github.com:octo/rafu.git", sha: "abc") == nil)
        #expect(
            GitHubRemoteURL.commitURL(remote: "git@github.com:octo/rafu.git", sha: "zzzzzzzz")
                == nil)
    }
}
