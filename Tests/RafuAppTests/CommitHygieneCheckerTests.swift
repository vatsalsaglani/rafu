import Testing

@testable import RafuApp

@Suite("Commit hygiene checker")
struct CommitHygieneCheckerTests {
    @Test("Clean paths produce no findings")
    func cleanPaths() {
        let findings = CommitHygieneChecker.findings(
            for: ["Sources/App/main.swift", "README.md", "docs/notes.txt"]
        )
        #expect(findings.isEmpty)
    }

    @Test("A bare .env file is flagged as a secret")
    func bareEnvFile() throws {
        let findings = CommitHygieneChecker.findings(for: [".env"])
        let finding = try #require(findings.first)
        #expect(finding.category == .secret)
        #expect(finding.path == ".env")
    }

    @Test("A dotted .env variant is flagged as a secret")
    func dottedEnvVariant() throws {
        let findings = CommitHygieneChecker.findings(for: [".env.production"])
        #expect(try #require(findings.first).category == .secret)
    }

    @Test(
        "Allow-listed .env example/sample/template files are never flagged",
        arguments: [".env.example", ".env.sample", ".env.template"]
    )
    func envAllowList(name: String) {
        #expect(CommitHygieneChecker.findings(for: [name]).isEmpty)
        #expect(CommitHygieneChecker.findings(for: ["config/\(name)"]).isEmpty)
    }

    @Test(
        "Private key and certificate extensions are flagged as secrets",
        arguments: ["identity.pem", "server.key", "cert.p12", "cert.pfx", "store.keystore"]
    )
    func secretExtensions(name: String) throws {
        let finding = try #require(CommitHygieneChecker.findings(for: [name]).first)
        #expect(finding.category == .secret)
    }

    @Test(
        "SSH private keys are flagged but their .pub counterpart is not",
        arguments: ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
    )
    func sshPrivateKeys(name: String) {
        #expect(CommitHygieneChecker.findings(for: [".ssh/\(name)"]).first?.category == .secret)
        #expect(CommitHygieneChecker.findings(for: [".ssh/\(name).pub"]).isEmpty)
    }

    @Test("credentials.json is flagged as a secret")
    func credentialsJSON() {
        #expect(
            CommitHygieneChecker.findings(for: ["config/credentials.json"]).first?.category
                == .secret)
    }

    @Test(
        "Vendored dependency directories are flagged, case-insensitively",
        arguments: ["node_modules", ".venv", "venv", "vendor", "Pods", "PODS"]
    )
    func dependencyDirectories(directory: String) throws {
        let finding = try #require(
            CommitHygieneChecker.findings(for: ["\(directory)/pkg/index.js"]).first)
        #expect(finding.category == .dependencyDirectory)
    }

    @Test(
        "Build-output directories are flagged",
        arguments: ["dist", "build", ".build", "target", "out", "__pycache__"]
    )
    func buildArtifactDirectories(directory: String) throws {
        let finding = try #require(
            CommitHygieneChecker.findings(for: ["\(directory)/output.bin"]).first)
        #expect(finding.category == .buildArtifact)
    }

    @Test(
        "Compiled artifact extensions are flagged",
        arguments: ["module.pyc", "object.o", "Main.class"]
    )
    func buildArtifactExtensions(name: String) throws {
        let finding = try #require(CommitHygieneChecker.findings(for: [name]).first)
        #expect(finding.category == .buildArtifact)
    }

    @Test("OS cruft files are flagged, case-insensitively")
    func osCruft() {
        #expect(
            CommitHygieneChecker.findings(for: ["src/.DS_Store"]).first?.category == .osCruft)
        #expect(
            CommitHygieneChecker.findings(for: ["Windows/thumbs.db"]).first?.category == .osCruft)
    }

    @Test("Secret severity wins over dependency-directory and build-artifact matches")
    func severityOrdering() throws {
        let finding = try #require(
            CommitHygieneChecker.findings(for: ["node_modules/pkg/dist/identity.pem"]).first)
        #expect(finding.category == .secret)
    }

    @Test("One finding is produced per flagged path, in input order")
    func oneFindingPerPath() {
        let paths = [".env", "src/main.swift", "node_modules/pkg/index.js", ".DS_Store"]
        let findings = CommitHygieneChecker.findings(for: paths)
        #expect(findings.map(\.path) == [".env", "node_modules/pkg/index.js", ".DS_Store"])
    }

    @Test("Large binaries are not flagged unless fileSizes is populated")
    func largeBinaryDeferred() {
        #expect(CommitHygieneChecker.findings(for: ["assets/movie.mov"]).isEmpty)
        let findings = CommitHygieneChecker.findings(
            for: ["assets/movie.mov"],
            fileSizes: ["assets/movie.mov": 6 * 1_024 * 1_024]
        )
        #expect(findings.first?.category == .largeBinary)
    }
}
