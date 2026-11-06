import Foundation

/// The fixed set of native renderers an MDX component can map to (ADR 0034).
/// A registry file can only choose among these; it can never add code.
nonisolated enum MDXRendererKind: String, Sendable, CaseIterable, Equatable {
    case callout
    case card
    case checklist
    case questions
    case fileTree
    case svg
}

/// Maps MDX component names to native renderers.
///
/// Built-in entries cover the vplan vocabulary. A workspace can add or
/// override entries in `.rafu/mdx-components.json`:
///
/// ```json
/// { "components": { "Note": { "renderer": "callout" } } }
/// ```
///
/// The file is untrusted input: it is read once per preview load, bounded
/// to `maxFileBytes`, and only a known `MDXRendererKind` is accepted.
nonisolated struct MDXComponentRegistry: Sendable, Equatable {
    static let fileName = "mdx-components.json"
    static let directoryName = ".rafu"
    static let maxFileBytes = 256 * 1024
    static let maxEntries = 256
    /// Ancestor directories searched above the document for the file.
    static let maxSearchDepth = 32

    static let builtIn = MDXComponentRegistry(entries: [
        "Callout": .callout,
        "Phase": .card,
        "Checklist": .checklist,
        "Questions": .questions,
        "FileTree": .fileTree,
        "Svg": .svg,
    ])

    let entries: [String: MDXRendererKind]
    /// Plain-language problems found in the registry file. Shown once above
    /// the preview; never fatal.
    var warnings: [String] = []

    func renderer(for name: String) -> MDXRendererKind? { entries[name] }

    /// Built-in entries with `data` applied on top. Invalid entries are
    /// skipped with a warning; an unreadable file keeps the built-ins.
    static func decode(_ data: Data, base: MDXComponentRegistry = .builtIn)
        -> MDXComponentRegistry
    {
        var registry = base
        guard data.count <= maxFileBytes else {
            registry.warnings.append(
                "\(directoryName)/\(fileName) is larger than 256 KB and was ignored.")
            return registry
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let root = object as? [String: Any],
            let components = root["components"] as? [String: Any]
        else {
            registry.warnings.append(
                "\(directoryName)/\(fileName) is not valid. Expected a \"components\" object.")
            return registry
        }
        var entries = base.entries
        var accepted = 0
        for name in components.keys.sorted() {
            guard accepted < maxEntries else {
                registry.warnings.append(
                    "Only the first \(maxEntries) component entries were used.")
                break
            }
            guard isValidComponentName(name) else {
                registry.warnings.append("\"\(name)\" is not a valid component name.")
                continue
            }
            guard
                let entry = components[name] as? [String: Any],
                let rendererName = entry["renderer"] as? String
            else {
                registry.warnings.append("\"\(name)\" has no \"renderer\" value.")
                continue
            }
            guard let kind = MDXRendererKind(rawValue: rendererName) else {
                registry.warnings.append(
                    "\"\(name)\" uses unknown renderer \"\(rendererName)\".")
                continue
            }
            entries[name] = kind
            accepted += 1
        }
        return MDXComponentRegistry(entries: entries, warnings: registry.warnings)
    }

    /// Finds `.rafu/mdx-components.json` in the document's directory or the
    /// nearest ancestor. The search stops at the first directory that holds
    /// `.git`, at the home directory, or at the filesystem root. Blocking
    /// file I/O: call it off the main actor.
    static func load(forDocumentAt documentURL: URL) -> MDXComponentRegistry {
        guard documentURL.isFileURL else { return .builtIn }
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.standardizedFileURL.path
        var directory = documentURL.deletingLastPathComponent().standardizedFileURL
        for _ in 0..<maxSearchDepth {
            let candidate =
                directory
                .appendingPathComponent(directoryName, isDirectory: true)
                .appendingPathComponent(fileName, isDirectory: false)
            if fileManager.fileExists(atPath: candidate.path) {
                return load(fileAt: candidate)
            }
            let path = directory.path
            if path == "/" || path == home
                || fileManager.fileExists(atPath: directory.appendingPathComponent(".git").path)
            {
                break
            }
            directory = directory.deletingLastPathComponent()
        }
        return .builtIn
    }

    /// Reads at most `maxFileBytes + 1` bytes so an oversized file is never
    /// loaded whole.
    static func load(fileAt url: URL) -> MDXComponentRegistry {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            var registry = MDXComponentRegistry.builtIn
            registry.warnings.append("\(directoryName)/\(fileName) could not be read.")
            return registry
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: maxFileBytes + 1)) ?? Data()
        return decode(data)
    }

    static func isValidComponentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, first >= "A", first <= "Z",
            name.unicodeScalars.count <= 64
        else { return false }
        return name.unicodeScalars.allSatisfy { MDXBlockScanner.isNameScalar($0) || $0 == "." }
    }
}
