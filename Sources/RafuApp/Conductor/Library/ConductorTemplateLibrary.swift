import Foundation

nonisolated struct ConductorBundledTemplate: Equatable, Identifiable, Sendable {
    nonisolated struct File: Equatable, Sendable {
        nonisolated enum Kind: String, CaseIterable, Sendable {
            case agent = "agents"
            case workflow = "workflows"
        }

        let kind: Kind
        let fileName: String

        var relativePath: String { "\(kind.rawValue)/\(fileName)" }
    }

    let id: String
    let displayName: String
    let summary: String
    let files: [File]
}

nonisolated enum ConductorBundledTemplateError: Error, Equatable, LocalizedError, Sendable {
    case resourcesUnavailable
    case unknownTemplate(String)
    case unsafeResourcePath(String)
    case missingResource(String)
    case resourceTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .resourcesUnavailable:
            "The bundled Ensemble templates are unavailable."
        case .unknownTemplate(let id):
            "Template \"\(id)\" is not bundled with this version of Rafu."
        case .unsafeResourcePath(let path):
            "Template resource \"\(path)\" has an unsafe path."
        case .missingResource(let path):
            "Template resource \"\(path)\" is missing."
        case .resourceTooLarge(let path):
            "Template resource \"\(path)\" exceeds Rafu's 1 MiB template-file limit."
        }
    }
}

/// Manifest for the read-only template files copied by SwiftPM into
/// `Bundle.module`. The manifest is code so the product never trusts an
/// unbounded directory enumeration or an editable second template index.
nonisolated struct ConductorBundledTemplateCatalog: Sendable {
    static let maximumTemplateFileBytes = 1_048_576

    let resourceRootURL: URL

    static let templates: [ConductorBundledTemplate] = [
        ConductorBundledTemplate(
            id: "advise-implement-document",
            displayName: "Advise, Implement, Document",
            summary: "Three roles across Claude Code, Codex, and Gemini CLI.",
            files: [
                .init(kind: .agent, fileName: "advisor.md"),
                .init(kind: .agent, fileName: "implementor.md"),
                .init(kind: .agent, fileName: "documentor.md"),
                .init(kind: .workflow, fileName: "advise-implement-document.md"),
            ]),
        ConductorBundledTemplate(
            id: "review-only",
            displayName: "Review Only",
            summary: "One read-only reviewer role.",
            files: [
                .init(kind: .agent, fileName: "reviewer.md"),
                .init(kind: .workflow, fileName: "review-only.md"),
            ]),
        ConductorBundledTemplate(
            id: "implement-review",
            displayName: "Implement and Review",
            summary: "A writable implementor, read-only reviewer, and merge gate.",
            files: [
                .init(kind: .agent, fileName: "implementor.md"),
                .init(kind: .agent, fileName: "reviewer.md"),
                .init(kind: .workflow, fileName: "implement-review.md"),
            ]),
    ]

    /// `Bundle.module` is main-actor isolated in RafuApp's default-isolated
    /// target. Resolve it once on the UI actor, then pass the URL into the
    /// off-main reader/instantiator.
    @MainActor
    static func bundled() throws -> ConductorBundledTemplateCatalog {
        guard
            let root = Bundle.module.url(
                forResource: "EnsembleTemplates",
                withExtension: nil)
        else {
            throw ConductorBundledTemplateError.resourcesUnavailable
        }
        return ConductorBundledTemplateCatalog(resourceRootURL: root)
    }

    func template(id: String) throws -> ConductorBundledTemplate {
        guard let template = Self.templates.first(where: { $0.id == id }) else {
            throw ConductorBundledTemplateError.unknownTemplate(id)
        }
        return template
    }

    func data(
        for file: ConductorBundledTemplate.File,
        in template: ConductorBundledTemplate
    ) throws -> Data {
        guard Self.isSafePathComponent(template.id),
            Self.isSafePathComponent(file.kind.rawValue),
            Self.isSafePathComponent(file.fileName)
        else {
            throw ConductorBundledTemplateError.unsafeResourcePath(
                "\(template.id)/\(file.relativePath)")
        }
        let relativePath = "\(template.id)/\(file.relativePath)"
        let url = resourceRootURL.appending(path: relativePath, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ConductorBundledTemplateError.missingResource(relativePath)
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true else {
            throw ConductorBundledTemplateError.missingResource(relativePath)
        }
        guard (values.fileSize ?? 0) <= Self.maximumTemplateFileBytes else {
            throw ConductorBundledTemplateError.resourceTooLarge(relativePath)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data =
            try handle.read(upToCount: Self.maximumTemplateFileBytes + 1)
            ?? Data()
        guard data.count <= Self.maximumTemplateFileBytes else {
            throw ConductorBundledTemplateError.resourceTooLarge(relativePath)
        }
        return data
    }

    private static func isSafePathComponent(_ value: String) -> Bool {
        !value.isEmpty && value != "." && value != ".."
            && !value.contains("/") && !value.contains("\\")
    }
}

nonisolated enum ConductorTemplateDestination: Equatable, Sendable {
    case repository(workspaceRoot: URL)
    case userGlobal(libraryRoot: URL)

    var scope: ConductorDefinitionScope {
        switch self {
        case .repository: .repository
        case .userGlobal: .userGlobal
        }
    }

    var definitionsRootURL: URL {
        switch self {
        case .repository(let workspaceRoot):
            RafuDotDirectory(workspaceRoot: workspaceRoot).directoryURL
        case .userGlobal(let libraryRoot):
            libraryRoot
        }
    }
}

nonisolated enum ConductorTemplateExistingFilePolicy: Equatable, Sendable {
    case requireConfirmation
    case replaceConfirmed
}

nonisolated struct ConductorTemplateInstantiationResult: Equatable, Sendable {
    let created: [String]
    let replaced: [String]
    let unchanged: [String]
    let conflicts: [String]

    var requiresConfirmation: Bool { !conflicts.isEmpty }
    var didChangeAnything: Bool { !created.isEmpty || !replaced.isEmpty }
}

nonisolated enum ConductorTemplateInstantiationError: Error, Equatable, LocalizedError, Sendable {
    case pathIsNotDirectory(String)
    case unsafePath(String)
    case destinationFileTooLarge(String)
    case destinationChanged(String)

    var errorDescription: String? {
        switch self {
        case .pathIsNotDirectory(let path):
            "\"\(path)\" already exists and is not a directory."
        case .unsafePath(let path):
            "\"\(path)\" must not be a symbolic link."
        case .destinationFileTooLarge(let path):
            "\"\(path)\" exceeds Rafu's 1 MiB definition-file limit."
        case .destinationChanged(let path):
            "\"\(path)\" changed while the template was being created. Nothing was overwritten."
        }
    }
}

/// Explicit template-copy action. It classifies every destination before
/// creating directories or files, making the default call both idempotent and
/// all-or-nothing when confirmation is required.
nonisolated struct ConductorTemplateInstantiator: Sendable {
    private let catalog: ConductorBundledTemplateCatalog

    init(catalog: ConductorBundledTemplateCatalog) {
        self.catalog = catalog
    }

    @concurrent
    func instantiate(
        templateID: String,
        at destination: ConductorTemplateDestination,
        existingFilePolicy: ConductorTemplateExistingFilePolicy = .requireConfirmation
    ) async throws -> ConductorTemplateInstantiationResult {
        try Task.checkCancellation()
        let template = try catalog.template(id: templateID)
        let root = destination.definitionsRootURL
        try validateDirectoryIfPresent(root)

        let sources = try template.files.map { file in
            (file: file, data: try catalog.data(for: file, in: template))
        }
        let targets = sources.map { source in
            (
                file: source.file,
                data: source.data,
                relativePath: source.file.relativePath,
                url: root.appending(path: source.file.relativePath, directoryHint: .notDirectory)
            )
        }

        for kind in ConductorBundledTemplate.File.Kind.allCases {
            try validateDirectoryIfPresent(
                root.appending(path: kind.rawValue, directoryHint: .isDirectory))
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
            return ConductorTemplateInstantiationResult(
                created: [],
                replaced: [],
                unchanged: unchanged,
                conflicts: conflicts)
        }

        for kind in ConductorBundledTemplate.File.Kind.allCases {
            let directory = root.appending(path: kind.rawValue, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            try validateDirectoryIfPresent(directory)
        }

        var written: [String] = []
        var replaced: [String] = []
        for target in targets where !unchanged.contains(target.relativePath) {
            try Task.checkCancellation()
            let latest = try classifyExistingFile(at: target.url, expected: target.data)
            switch latest {
            case .identical:
                unchanged.append(target.relativePath)
                continue
            case .different:
                guard existingFilePolicy == .replaceConfirmed else {
                    throw ConductorTemplateInstantiationError.destinationChanged(
                        target.relativePath)
                }
                try target.data.write(to: target.url, options: .atomic)
                replaced.append(target.relativePath)
            case .missing:
                try writeNewFileAtomically(target.data, to: target.url)
                written.append(target.relativePath)
            }
        }

        return ConductorTemplateInstantiationResult(
            created: written.sorted(),
            replaced: replaced.sorted(),
            unchanged: Array(Set(unchanged)).sorted(),
            conflicts: [])
    }

    private enum ExistingFile {
        case missing
        case identical
        case different
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
            throw ConductorTemplateInstantiationError.unsafePath(url.path)
        }
        guard values.isRegularFile == true else {
            throw ConductorTemplateInstantiationError.pathIsNotDirectory(url.path)
        }
        guard (values.fileSize ?? 0) <= ConductorDefinitionLibrary.maximumDefinitionFileBytes
        else {
            throw ConductorTemplateInstantiationError.destinationFileTooLarge(url.path)
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
            throw ConductorTemplateInstantiationError.pathIsNotDirectory(url.path)
        }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else {
            throw ConductorTemplateInstantiationError.unsafePath(url.path)
        }
    }

    /// Foundation traps when `.atomic` and `.withoutOverwriting` are passed
    /// together. Publish a fully written same-directory temporary file via a
    /// hard link instead: link creation is atomic and fails rather than
    /// replacing a destination that appeared after preflight.
    private func writeNewFileAtomically(_ data: Data, to destination: URL) throws {
        let manager = FileManager.default
        let temporary = destination.deletingLastPathComponent()
            .appending(
                path: ".rafu-template-\(UUID().uuidString).tmp",
                directoryHint: .notDirectory)
        defer { try? manager.removeItem(at: temporary) }
        try data.write(to: temporary, options: .atomic)
        do {
            try manager.linkItem(at: temporary, to: destination)
        } catch {
            if manager.fileExists(atPath: destination.path) {
                throw ConductorTemplateInstantiationError.destinationChanged(destination.path)
            }
            throw error
        }
    }
}
