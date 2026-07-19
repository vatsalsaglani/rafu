import Foundation

/// One path the commit-hygiene heuristic flagged as likely not belonging in a
/// commit, plus the reason a human can read at a glance. Pure and
/// process-free — callers supply already-known staged paths (see
/// `WorkspaceSession.commitHygieneFindings`).
nonisolated struct CommitHygieneFinding: Identifiable, Hashable, Sendable {
    enum Category: String, Hashable, Sendable {
        case secret
        case dependencyDirectory
        case buildArtifact
        case osCruft
        case largeBinary
    }

    let path: String
    let reason: String
    let category: Category

    var id: String { path }
}

/// Pure heuristic scan of staged paths for files that usually should never
/// be committed: secrets, vendored dependency trees, build output, and OS
/// cruft. Advisory only — this never blocks a commit, it only informs the
/// composer's inline warning (see `GitInspectorView.commitComposer`).
///
/// `fileSizes`/`largeBinaryThreshold` exist for a future large-binary check;
/// no caller currently populates `fileSizes`, so `.largeBinary` never fires
/// yet. Keeping the parameter now avoids a public-API break when that check
/// is wired up.
nonisolated enum CommitHygieneChecker {
    /// Returns at most one finding per path — when a path matches more than
    /// one category (e.g. a `.pem` file inside `node_modules/`), the highest
    /// -severity match wins: secret, then dependency directory, then build
    /// artifact, then OS cruft, then large binary.
    static func findings(
        for paths: [String],
        fileSizes: [String: Int] = [:],
        largeBinaryThreshold: Int = 5 * 1_024 * 1_024
    ) -> [CommitHygieneFinding] {
        paths.compactMap {
            finding(for: $0, fileSizes: fileSizes, largeBinaryThreshold: largeBinaryThreshold)
        }
    }

    // MARK: - Secrets

    private static let secretExactNames: Set<String> = [
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", "credentials.json",
    ]
    private static let secretExtensions: Set<String> = ["pem", "key", "p12", "pfx", "keystore"]
    private static let secretEnvExceptions: Set<String> = [
        ".env.example", ".env.sample", ".env.template",
    ]

    // MARK: - Dependency directories

    private static let dependencyDirectoryNames: Set<String> = [
        "node_modules", ".venv", "venv", "vendor", "pods",
    ]

    // MARK: - Build artifacts

    private static let buildArtifactDirectoryNames: Set<String> = [
        "dist", "build", ".build", "target", "out", "__pycache__",
    ]
    private static let buildArtifactExtensions: Set<String> = ["pyc", "o", "class"]

    // MARK: - OS cruft

    private static let osCruftNames: Set<String> = [".ds_store", "thumbs.db"]

    private static func finding(
        for path: String,
        fileSizes: [String: Int],
        largeBinaryThreshold: Int
    ) -> CommitHygieneFinding? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard let lastComponent = components.last else { return nil }
        let lowerLast = lastComponent.lowercased()
        let lowerComponents = Set(components.map { $0.lowercased() })

        if let reason = secretReason(lastComponent: lastComponent, lowerLast: lowerLast) {
            return CommitHygieneFinding(path: path, reason: reason, category: .secret)
        }
        if !lowerComponents.isDisjoint(with: dependencyDirectoryNames) {
            return CommitHygieneFinding(
                path: path,
                reason: "Inside a vendored dependency directory.",
                category: .dependencyDirectory
            )
        }
        if let reason = buildArtifactReason(lowerComponents: lowerComponents, lowerLast: lowerLast)
        {
            return CommitHygieneFinding(path: path, reason: reason, category: .buildArtifact)
        }
        if osCruftNames.contains(lowerLast) {
            return CommitHygieneFinding(
                path: path,
                reason: "Operating-system generated file.",
                category: .osCruft
            )
        }
        if let size = fileSizes[path], size >= largeBinaryThreshold {
            return CommitHygieneFinding(
                path: path,
                reason: "Large binary file (\(size) bytes).",
                category: .largeBinary
            )
        }
        return nil
    }

    private static func secretReason(lastComponent: String, lowerLast: String) -> String? {
        if lowerLast == ".env" {
            return "Environment file — likely contains secrets."
        }
        if lowerLast.hasPrefix(".env.") {
            guard !secretEnvExceptions.contains(lowerLast) else { return nil }
            return "Environment file — likely contains secrets."
        }
        if secretExactNames.contains(lowerLast) {
            return lowerLast == "credentials.json"
                ? "Credentials file — likely contains secrets."
                : "Private SSH key."
        }
        let extensionComponent = (lastComponent as NSString).pathExtension.lowercased()
        if !extensionComponent.isEmpty, secretExtensions.contains(extensionComponent) {
            return "Private key or certificate file."
        }
        return nil
    }

    private static func buildArtifactReason(lowerComponents: Set<String>, lowerLast: String)
        -> String?
    {
        if !lowerComponents.isDisjoint(with: buildArtifactDirectoryNames) {
            return "Inside a build-output directory."
        }
        let extensionComponent = (lowerLast as NSString).pathExtension
        if !extensionComponent.isEmpty, buildArtifactExtensions.contains(extensionComponent) {
            return "Compiled build artifact."
        }
        return nil
    }
}
