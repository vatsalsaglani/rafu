import Foundation

public enum AgentHandoffWriteError: Error, Equatable, Sendable {
    /// The project folder is missing or is not a folder.
    case projectUnavailable
    /// The target would leave the project folder (for example a symbolic
    /// link). Nothing was written.
    case outsideProject
    /// No free folder name was found.
    case noFreeFolder
    /// A file name that Rafu did not make.
    case invalidFileName
    /// The disk refused a write.
    case writeFailed
}

/// One image file to write beside `HANDOFF.md`.
public struct AgentHandoffImageData: Sendable {
    public let name: String
    public let data: Data

    public init(name: String, data: Data) {
        self.name = name
        self.data = data
    }
}

public struct AgentHandoffWriteResult: Equatable, Sendable {
    /// `<project>/.rafu/handoffs/<name>`
    public let folderURL: URL
    public let markdownURL: URL
    public let imageURLs: [URL]
    /// `<name>`, the folder name.
    public var folderName: String { folderURL.lastPathComponent }
}

/// Writes `.rafu/handoffs/<yyyy-MM-dd-HHmm>-<slug>/HANDOFF.md` and its image
/// files. Every path is checked to stay inside the project folder after
/// symbolic links are resolved. Files are written atomically. An existing
/// folder is never reused: a numeric suffix makes a new one.
public enum AgentHandoffWriter {
    public static let relativeFolder = ".rafu/handoffs"
    public static let markdownName = "HANDOFF.md"

    // MARK: Names

    /// `2026-10-18-1430-fix-login-bug`
    public static func folderName(
        date: Date, title: String, timeZone: TimeZone = .current
    ) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(width - text.count, 0)) + text
        }
        let stamp =
            "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))-"
            + "\(pad(parts.hour, 2))\(pad(parts.minute, 2))"
        return stamp + "-" + slug(title)
    }

    /// Lowercase letters and digits joined by single dashes, at most 40
    /// characters. `session` when nothing is left.
    public static func slug(_ title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
        var result = ""
        var lastWasDash = true
        for scalar in folded.unicodeScalars {
            let isWord =
                (scalar.value >= 0x61 && scalar.value <= 0x7A)
                || (scalar.value >= 0x30 && scalar.value <= 0x39)
            if isWord {
                result.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                result += "-"
                lastWasDash = true
            }
            if result.count >= 60 { break }
        }
        var trimmed = String(result.prefix(40))
        while trimmed.hasSuffix("-") { trimmed.removeLast() }
        while trimmed.hasPrefix("-") { trimmed.removeFirst() }
        return trimmed.isEmpty ? "session" : trimmed
    }

    /// Only the names Rafu makes: `image-<digits>.png|jpg|gif|webp`.
    static func isImageFileName(_ name: String) -> Bool {
        guard name.hasPrefix("image-"), let dot = name.lastIndex(of: ".") else { return false }
        let number = name[name.index(name.startIndex, offsetBy: 6)..<dot]
        let ext = name[name.index(after: dot)...]
        return !number.isEmpty && number.count <= 4 && number.allSatisfy(\.isASCII)
            && number.allSatisfy(\.isNumber)
            && AgentHandoffImageFormat.allCases.contains { $0.fileExtension == ext }
    }

    // MARK: Writing

    public static func write(
        markdown: String, images: [AgentHandoffImageData], projectRoot: URL, baseName: String
    ) throws -> AgentHandoffWriteResult {
        guard baseName.range(of: #"^[a-z0-9][a-z0-9-]*$"#, options: .regularExpression) != nil
        else { throw AgentHandoffWriteError.invalidFileName }
        guard images.allSatisfy({ isImageFileName($0.name) }) else {
            throw AgentHandoffWriteError.invalidFileName
        }
        let root = try resolvedRoot(projectRoot)
        let manager = FileManager.default
        let rafu = root.appendingPathComponent(".rafu", isDirectory: true)
        try ensureDirectory(rafu, inside: root)
        let handoffs = rafu.appendingPathComponent("handoffs", isDirectory: true)
        try ensureDirectory(handoffs, inside: root)

        var folder: URL?
        for attempt in 1...99 {
            let name = attempt == 1 ? baseName : "\(baseName)-\(attempt)"
            let candidate = handoffs.appendingPathComponent(name, isDirectory: true)
            do {
                try manager.createDirectory(
                    at: candidate, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o755])
                folder = candidate
                break
            } catch {
                // Taken by something else: try the next suffix. Any other
                // failure ends here.
                if manager.fileExists(atPath: candidate.path) { continue }
                throw AgentHandoffWriteError.writeFailed
            }
        }
        guard let folder else { throw AgentHandoffWriteError.noFreeFolder }
        do {
            let resolved = folder.resolvingSymlinksInPath().standardizedFileURL
            guard
                AgentHistoryPath.isPath(
                    resolved.path, inside: handoffs.resolvingSymlinksInPath().path)
            else { throw AgentHandoffWriteError.outsideProject }
            var imageURLs: [URL] = []
            for image in images {
                let url = folder.appendingPathComponent(image.name)
                try image.data.write(to: url, options: .atomic)
                imageURLs.append(url)
            }
            let markdownURL = folder.appendingPathComponent(markdownName)
            try Data(markdown.utf8).write(to: markdownURL, options: .atomic)
            return AgentHandoffWriteResult(
                folderURL: folder, markdownURL: markdownURL, imageURLs: imageURLs)
        } catch {
            try? manager.removeItem(at: folder)
            if let known = error as? AgentHandoffWriteError { throw known }
            throw AgentHandoffWriteError.writeFailed
        }
    }

    private static func resolvedRoot(_ projectRoot: URL) throws -> URL {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { throw AgentHandoffWriteError.projectUnavailable }
        return root
    }

    /// Makes `url` a real directory inside `root`. A link that points
    /// outside, or a file in the way, stops the write.
    private static func ensureDirectory(_ url: URL, inside root: URL) throws {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else { throw AgentHandoffWriteError.outsideProject }
        } else {
            do {
                try manager.createDirectory(at: url, withIntermediateDirectories: false)
            } catch {
                throw AgentHandoffWriteError.writeFailed
            }
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard AgentHistoryPath.isPath(resolved, inside: root.path), resolved != root.path else {
            throw AgentHandoffWriteError.outsideProject
        }
    }

    // MARK: .gitignore

    public enum GitignoreState: Equatable, Sendable {
        /// The folder has no `.git`; Rafu offers nothing.
        case notGitRepository
        /// A line already covers `.rafu/handoffs/`.
        case alreadyIgnored
        /// A line should be added.
        case needsEntry
    }

    static let gitignoreEntry = ".rafu/handoffs/"
    private static let coveringLines: Set<String> = [
        ".rafu", ".rafu/", "/.rafu", "/.rafu/", ".rafu/handoffs", ".rafu/handoffs/",
        "/.rafu/handoffs", "/.rafu/handoffs/", ".rafu/*", "/.rafu/*",
    ]

    public static func gitignoreState(projectRoot: URL) -> GitignoreState {
        let root = projectRoot.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path)
        else { return .notGitRepository }
        guard let existing = readGitignore(root) else { return .needsEntry }
        return covers(existing) ? .alreadyIgnored : .needsEntry
    }

    private static func gitignoreURL(_ root: URL) -> URL {
        root.appendingPathComponent(".gitignore")
    }

    private static func readGitignore(_ root: URL) -> Data? {
        try? Data(contentsOf: gitignoreURL(root).resolvingSymlinksInPath())
    }

    private static func covers(_ data: Data) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(whereSeparator: \.isNewline).contains {
            coveringLines.contains($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Adds `.rafu/handoffs/` as a new last line. Other lines stay byte for
    /// byte as they were. Returns `false` when a line already covers it.
    @discardableResult
    public static func appendGitignoreEntry(projectRoot: URL) throws -> Bool {
        let root = try resolvedRoot(projectRoot)
        let link = gitignoreURL(root)
        let target = link.resolvingSymlinksInPath().standardizedFileURL
        guard AgentHistoryPath.isPath(target.path, inside: root.path) else {
            throw AgentHandoffWriteError.outsideProject
        }
        let existing = (try? Data(contentsOf: target)) ?? Data()
        if covers(existing) { return false }
        var updated = existing
        if let last = existing.last, last != 0x0A { updated.append(0x0A) }
        updated.append(Data((gitignoreEntry + "\n").utf8))
        do {
            try updated.write(to: target, options: .atomic)
        } catch {
            throw AgentHandoffWriteError.writeFailed
        }
        return true
    }
}
