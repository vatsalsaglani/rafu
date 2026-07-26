import Foundation

nonisolated struct ConductorBundledSkillFile: Equatable, Sendable {
    let pathComponents: [String]

    var relativePath: String {
        pathComponents.joined(separator: "/")
    }
}

nonisolated struct ConductorBundledSkillMetadata: Equatable, Sendable {
    let name: String
    let description: String
    let targetsVerbVersion: Int
}

nonisolated enum ConductorBundledSkillError: Error, Equatable, LocalizedError, Sendable {
    case resourcesUnavailable
    case unsafeResourcePath(String)
    case missingResource(String)
    case resourceTooLarge(String)
    case invalidMetadata(String)

    var errorDescription: String? {
        switch self {
        case .resourcesUnavailable:
            "The bundled Ensemble coordinator skill is unavailable."
        case .unsafeResourcePath(let path):
            "Skill resource \"\(path)\" has an unsafe path."
        case .missingResource(let path):
            "Skill resource \"\(path)\" is missing."
        case .resourceTooLarge(let path):
            "Skill resource \"\(path)\" exceeds Rafu's 1 MiB skill-file limit."
        case .invalidMetadata(let detail):
            "The bundled Ensemble coordinator skill has invalid metadata: \(detail)"
        }
    }
}

/// Code-declared manifest for the read-only coordinator skill. Rafu never
/// trusts a resource-directory listing when deciding what to install.
nonisolated struct ConductorBundledSkillCatalog: Sendable {
    static let skillIdentifier = "ensemble-with-rafu"
    static let maximumSkillFileBytes = 1_048_576
    static let files: [ConductorBundledSkillFile] = [
        .init(pathComponents: ["SKILL.md"]),
        .init(pathComponents: ["references", "verbs.md"]),
        .init(pathComponents: ["references", "file-formats.md"]),
        .init(pathComponents: ["references", "patterns.md"]),
        .init(pathComponents: ["references", "troubleshooting.md"]),
    ]

    let resourceRootURL: URL
    let manifest: [ConductorBundledSkillFile]

    init(
        resourceRootURL: URL,
        manifest: [ConductorBundledSkillFile] = Self.files
    ) {
        self.resourceRootURL = resourceRootURL
        self.manifest = manifest
    }

    /// `Bundle.module` is main-actor isolated in the default-isolated app
    /// target. Resolve only the URL here; bounded file reads happen in the
    /// installer's `@concurrent` methods.
    @MainActor
    static func bundled() throws -> ConductorBundledSkillCatalog {
        guard
            let root = Bundle.module.url(
                forResource: "EnsembleSkills",
                withExtension: nil)
        else {
            throw ConductorBundledSkillError.resourcesUnavailable
        }
        return ConductorBundledSkillCatalog(resourceRootURL: root)
    }

    func data(for file: ConductorBundledSkillFile) throws -> Data {
        let allComponents = [Self.skillIdentifier] + file.pathComponents
        guard allComponents.allSatisfy(Self.isSafePathComponent) else {
            throw ConductorBundledSkillError.unsafeResourcePath(
                allComponents.joined(separator: "/"))
        }

        let url = allComponents.reduce(resourceRootURL) { partial, component in
            partial.appending(path: component, directoryHint: .notDirectory)
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConductorBundledSkillError.missingResource(file.relativePath)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ConductorBundledSkillError.missingResource(file.relativePath)
        }
        guard (values.fileSize ?? 0) <= Self.maximumSkillFileBytes else {
            throw ConductorBundledSkillError.resourceTooLarge(file.relativePath)
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data =
            try handle.read(upToCount: Self.maximumSkillFileBytes + 1)
            ?? Data()
        guard data.count <= Self.maximumSkillFileBytes else {
            throw ConductorBundledSkillError.resourceTooLarge(file.relativePath)
        }
        return data
    }

    func metadata() throws -> ConductorBundledSkillMetadata {
        guard let skillFile = manifest.first(where: { $0.relativePath == "SKILL.md" }) else {
            throw ConductorBundledSkillError.invalidMetadata("SKILL.md is not in the manifest.")
        }
        let data = try data(for: skillFile)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ConductorBundledSkillError.invalidMetadata("SKILL.md is not UTF-8.")
        }
        let lines = ConductorFrontmatter.lines(of: text)
        let block = try ConductorFrontmatter.block(in: lines)
        var values: [String: String] = [:]
        for line in block.lines {
            guard let scalar = try ConductorFrontmatter.scalar(line) else { continue }
            values[scalar.key] = scalar.value
        }
        guard let name = values["name"], !name.isEmpty else {
            throw ConductorBundledSkillError.invalidMetadata("name is missing.")
        }
        guard let description = values["description"], !description.isEmpty else {
            throw ConductorBundledSkillError.invalidMetadata("description is missing.")
        }
        guard
            let rawVersion = values["targetsverbversion"],
            let targetsVerbVersion = Int(rawVersion)
        else {
            throw ConductorBundledSkillError.invalidMetadata(
                "targetsVerbVersion is missing or invalid.")
        }
        return ConductorBundledSkillMetadata(
            name: name,
            description: description,
            targetsVerbVersion: targetsVerbVersion)
    }

    static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }
}

nonisolated enum ConductorSkillDestination: Equatable, Sendable {
    case claudeCode
    /// A user-selected skills directory. Rafu creates
    /// `ensemble-with-rafu/` inside it.
    case custom(URL)
}

nonisolated enum ConductorSkillExistingFilePolicy: Equatable, Sendable {
    case requireConfirmation
    case replaceConfirmed
}

nonisolated struct ConductorSkillInstallationResult: Equatable, Sendable {
    let created: [String]
    let replaced: [String]
    let unchanged: [String]
    let conflicts: [String]
    let destinationDescription: String

    var requiresConfirmation: Bool { !conflicts.isEmpty }
    var didChangeAnything: Bool { !created.isEmpty || !replaced.isEmpty }
}

nonisolated enum ConductorSkillInstallationError: Error, Equatable, LocalizedError, Sendable {
    case pathIsNotDirectory(String)
    case unsafePath(String)
    case destinationFileTooLarge(String)
    case destinationChanged(String)

    var errorDescription: String? {
        switch self {
        case .pathIsNotDirectory(let path):
            "\"\(path)\" already exists with an incompatible file type."
        case .unsafePath(let path):
            "\"\(path)\" must not be a symbolic link."
        case .destinationFileTooLarge(let path):
            "\"\(path)\" exceeds Rafu's 1 MiB skill-file limit."
        case .destinationChanged(let path):
            "\"\(path)\" changed during installation. Nothing was overwritten."
        }
    }
}

/// Explicit, bounded coordinator-skill installation. All five destinations
/// are classified before any directory or file is created. Existing content
/// is never replaced until the caller repeats the action with confirmed
/// replacement policy.
nonisolated struct ConductorSkillInstaller: Sendable {
    private let catalog: ConductorBundledSkillCatalog
    private let homeDirectory: URL

    init(
        catalog: ConductorBundledSkillCatalog,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.catalog = catalog
        self.homeDirectory = homeDirectory
    }

    @concurrent
    func metadata() async throws -> ConductorBundledSkillMetadata {
        try Task.checkCancellation()
        return try catalog.metadata()
    }

    @concurrent
    func install(
        at destination: ConductorSkillDestination,
        existingFilePolicy: ConductorSkillExistingFilePolicy = .requireConfirmation
    ) async throws -> ConductorSkillInstallationResult {
        try Task.checkCancellation()
        let root = destinationRootURL(for: destination)
        let destinationDescription = root.path

        let sources = try catalog.manifest.map { file in
            try Task.checkCancellation()
            return (file: file, data: try catalog.data(for: file))
        }
        let targets = sources.map { source in
            let url = source.file.pathComponents.reduce(root) { partial, component in
                partial.appending(path: component, directoryHint: .notDirectory)
            }
            return (
                relativePath: source.file.relativePath,
                data: source.data,
                url: url
            )
        }

        let directories = destinationDirectories(for: destination, root: root)
        for directory in directories {
            try validateDirectoryIfPresent(directory)
        }

        var unchanged: [String] = []
        var conflicts: [String] = []
        for target in targets {
            try Task.checkCancellation()
            switch try classifyExistingFile(at: target.url, expected: target.data) {
            case .missing:
                break
            case .identical:
                unchanged.append(target.relativePath)
            case .different:
                conflicts.append(target.relativePath)
            }
        }

        if !conflicts.isEmpty, existingFilePolicy == .requireConfirmation {
            return ConductorSkillInstallationResult(
                created: [],
                replaced: [],
                unchanged: unchanged.sorted(),
                conflicts: conflicts.sorted(),
                destinationDescription: destinationDescription)
        }

        for directory in directories {
            try Task.checkCancellation()
            try createDirectoryIfMissing(directory)
        }

        var created: [String] = []
        var replaced: [String] = []
        for target in targets where !unchanged.contains(target.relativePath) {
            try Task.checkCancellation()
            switch try classifyExistingFile(at: target.url, expected: target.data) {
            case .identical:
                unchanged.append(target.relativePath)
            case .different:
                guard existingFilePolicy == .replaceConfirmed else {
                    throw ConductorSkillInstallationError.destinationChanged(
                        target.relativePath)
                }
                try target.data.write(to: target.url, options: .atomic)
                replaced.append(target.relativePath)
            case .missing:
                try writeNewFileAtomically(target.data, to: target.url)
                created.append(target.relativePath)
            }
        }

        return ConductorSkillInstallationResult(
            created: created.sorted(),
            replaced: replaced.sorted(),
            unchanged: Array(Set(unchanged)).sorted(),
            conflicts: [],
            destinationDescription: destinationDescription)
    }

    private enum ExistingFile {
        case missing
        case identical
        case different
    }

    private func destinationRootURL(for destination: ConductorSkillDestination) -> URL {
        let skillsDirectory =
            switch destination {
            case .claudeCode:
                homeDirectory
                    .appending(path: ".claude", directoryHint: .isDirectory)
                    .appending(path: "skills", directoryHint: .isDirectory)
            case .custom(let url):
                url
            }
        return skillsDirectory.appending(
            path: ConductorBundledSkillCatalog.skillIdentifier,
            directoryHint: .isDirectory)
    }

    private func destinationDirectories(
        for destination: ConductorSkillDestination,
        root: URL
    ) -> [URL] {
        let ancestors: [URL] =
            switch destination {
            case .claudeCode:
                [
                    homeDirectory,
                    homeDirectory.appending(path: ".claude", directoryHint: .isDirectory),
                    homeDirectory
                        .appending(path: ".claude", directoryHint: .isDirectory)
                        .appending(path: "skills", directoryHint: .isDirectory),
                ]
            case .custom(let url):
                [url]
            }
        return ancestors + [
            root,
            root.appending(path: "references", directoryHint: .isDirectory),
        ]
    }

    private func classifyExistingFile(at url: URL, expected: Data) throws -> ExistingFile {
        let manager = FileManager.default
        guard manager.fileExists(atPath: url.path) else { return .missing }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw ConductorSkillInstallationError.unsafePath(url.path)
        }
        guard values.isRegularFile == true else {
            throw ConductorSkillInstallationError.pathIsNotDirectory(url.path)
        }
        guard (values.fileSize ?? 0) <= ConductorBundledSkillCatalog.maximumSkillFileBytes
        else {
            throw ConductorSkillInstallationError.destinationFileTooLarge(url.path)
        }
        let existing = try Data(contentsOf: url, options: .mappedIfSafe)
        return existing == expected ? .identical : .different
    }

    private func validateDirectoryIfPresent(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return
        }
        guard isDirectory.boolValue else {
            throw ConductorSkillInstallationError.pathIsNotDirectory(url.path)
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ConductorSkillInstallationError.unsafePath(url.path)
        }
    }

    private func createDirectoryIfMissing(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            try validateDirectoryIfPresent(url)
            return
        }
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false)
        try validateDirectoryIfPresent(url)
    }

    /// Foundation traps when `.atomic` and `.withoutOverwriting` are combined.
    /// Publish a same-directory temporary file through an atomic hard link so
    /// a destination that appears after classification is never overwritten.
    private func writeNewFileAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appending(
                path: ".rafu-skill-\(UUID().uuidString).tmp",
                directoryHint: .notDirectory)
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try manager.linkItem(at: temporary, to: destination)
        } catch {
            if manager.fileExists(atPath: destination.path) {
                throw ConductorSkillInstallationError.destinationChanged(destination.path)
            }
            throw error
        }
    }
}
