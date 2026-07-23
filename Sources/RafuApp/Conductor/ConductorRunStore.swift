import Foundation

/// Why a run manifest could not be read or written. `reason` describes the
/// MANIFEST's structure only — never prompt text, artifact content, or
/// captured CLI output, none of which this store ever reads (ADR 0018: that
/// evidence stays on disk under `.rafu/runs/` and out of Rafu's logs).
nonisolated enum ConductorRunStoreError: Error, Equatable, LocalizedError, Sendable {
    /// A run id that is not safe as a single path component.
    case invalidRunID(String)
    /// `manifest.json` exists but this build cannot decode it — including
    /// the deliberate strict failure on an unrecognized `RunStepStatus`.
    case unreadableManifest(runID: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .invalidRunID(let id):
            "\"\(id)\" is not a valid run identifier."
        case .unreadableManifest(let runID, let reason):
            "Run \(runID) has an unreadable manifest: \(reason)"
        }
    }
}

/// Reads and writes `.rafu/runs/<id>/manifest.json` (ADR 0018: runs are repo
/// data, not app state — window restoration in `UserDefaults` is untouched).
///
/// A run manifest is EVIDENCE, so this store never repairs one: a corrupt or
/// unknown-state manifest surfaces as a typed error and the run reads as
/// unreadable, rather than being silently downgraded to something plausible.
nonisolated struct ConductorRunStore: Sendable {
    let directory: RafuDotDirectory

    init(directory: RafuDotDirectory) {
        self.directory = directory
    }

    init(workspaceRoot: URL) {
        self.init(directory: RafuDotDirectory(workspaceRoot: workspaceRoot))
    }

    static let manifestFileName = "manifest.json"

    /// Run ids become a single path component, so they are restricted to a
    /// conservative alphabet — no separators, no `.`/`..` traversal.
    ///
    /// A LEADING `.` is rejected too, which also covers `.` and `..`.
    /// `listRunIDs()` enumerates with `.skipsHiddenFiles`, so a dot-prefixed
    /// id would be writable but permanently invisible — a run whose evidence
    /// exists on disk yet never appears in the runs list is worse than a run
    /// that was refused up front (ADR 0018: runs are the merge gate's
    /// evidence).
    static func isValidRunID(_ id: String) -> Bool {
        guard !id.isEmpty, !id.hasPrefix(".") else { return false }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        return id.unicodeScalars.allSatisfy(allowed.contains)
    }

    func manifestURL(for runID: String) -> URL {
        directory.runDirectoryURL(for: runID)
            .appending(path: Self.manifestFileName, directoryHint: .notDirectory)
    }

    /// ISO-8601 timestamps and `[.sortedKeys, .prettyPrinted]` output so a
    /// committed manifest produces a stable, reviewable diff instead of
    /// re-ordering its keys on every save.
    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Atomically writes `manifest.json`, creating the run directory when
    /// needed. Re-saving replaces the file whole — a partially written
    /// manifest is never observable.
    @concurrent
    func save(_ manifest: ConductorRunManifest) async throws {
        guard Self.isValidRunID(manifest.id) else {
            throw ConductorRunStoreError.invalidRunID(manifest.id)
        }
        let runDirectory = directory.runDirectoryURL(for: manifest.id)
        try FileManager.default.createDirectory(
            at: runDirectory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(manifest)
        try data.write(to: manifestURL(for: manifest.id), options: .atomic)
    }

    /// `nil` when the run has no manifest yet; THROWS when one exists but
    /// cannot be trusted.
    @concurrent
    func load(runID: String) async throws -> ConductorRunManifest? {
        guard Self.isValidRunID(runID) else {
            throw ConductorRunStoreError.invalidRunID(runID)
        }
        let url = manifestURL(for: runID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            return try Self.makeDecoder().decode(ConductorRunManifest.self, from: data)
        } catch let error as DecodingError {
            throw ConductorRunStoreError.unreadableManifest(
                runID: runID, reason: Self.describe(error))
        }
    }

    /// Every run directory under `.rafu/runs/`, sorted. An absent `runs/`
    /// directory is simply "no runs yet", not an error.
    @concurrent
    func listRunIDs() async throws -> [String] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard
            manager.fileExists(atPath: directory.runsURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return [] }
        let entries = try manager.contentsOfDirectory(
            at: directory.runsURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles])
        return
            entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map(\.lastPathComponent)
            .filter(Self.isValidRunID)
            .sorted()
    }

    /// Structural summary only — deliberately does not include the decoder's
    /// full debug dump, which can quote arbitrary manifest values.
    private static func describe(_ error: DecodingError) -> String {
        switch error {
        case .dataCorrupted(let context):
            context.debugDescription
        case .keyNotFound(let key, _):
            "missing key \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            context.debugDescription
        @unknown default:
            "the manifest could not be decoded"
        }
    }
}
