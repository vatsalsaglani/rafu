import Foundation

/// A file that a session mentioned, and where it stands now. Rafu lists it
/// in `HANDOFF.md` and never copies it.
public struct AgentHandoffAttachment: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Inside the project folder, so the next agent can read it there.
        case inProject
        /// Exists, but outside the project folder. Not copied.
        case outsideProject
        /// Not on disk any more.
        case missing

        public var note: String {
            switch self {
            case .inProject: "available in the project"
            case .outsideProject: "outside the project — not copied"
            case .missing: "missing"
            }
        }
    }

    /// Relative to the project when the file is inside it, else absolute.
    public let path: String
    public let status: Status

    public init(path: String, status: Status) {
        self.path = path
        self.status = status
    }
}

public enum AgentHandoffAttachments {
    /// The longest list `HANDOFF.md` shows.
    public static let maximumCount = 100

    /// Every path the chosen entries mention, in order, without repeats.
    public static func paths(in turns: [[AgentHandoffItem]]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for turn in turns {
            for item in turn {
                for path in item.attachmentPaths where seen.insert(path).inserted {
                    result.append(path)
                }
            }
        }
        return result
    }

    /// Classifies paths against the project folder. Symbolic links are
    /// resolved first, so a link that leaves the project counts as outside.
    /// A relative path is read against `workingDirectory`, then the project.
    public static func classify(
        _ rawPaths: [String], projectRoot: URL, workingDirectory: String?
    ) -> [AgentHandoffAttachment] {
        let root = AgentHistoryPath.normalized(
            projectRoot.resolvingSymlinksInPath().standardizedFileURL.path)
        let manager = FileManager.default
        var result: [AgentHandoffAttachment] = []
        var seen: Set<String> = []
        for raw in rawPaths {
            guard result.count < maximumCount else { break }
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !text.contains("\n") else { continue }
            var candidates: [String] = []
            if text.hasPrefix("/") {
                candidates = [text]
            } else {
                if let workingDirectory, workingDirectory.hasPrefix("/") {
                    candidates.append(workingDirectory + "/" + text)
                }
                candidates.append(root + "/" + text)
            }
            let normalized = candidates.map(AgentHistoryPath.normalized)
            let existing = normalized.first { manager.fileExists(atPath: $0) }
            let attachment: AgentHandoffAttachment
            if let existing {
                let resolved = AgentHistoryPath.normalized(
                    URL(fileURLWithPath: existing).resolvingSymlinksInPath().path)
                if AgentHistoryPath.isPath(resolved, inside: root), resolved != root {
                    attachment = AgentHandoffAttachment(
                        path: String(resolved.dropFirst(root.count + 1)), status: .inProject)
                } else {
                    attachment = AgentHandoffAttachment(path: existing, status: .outsideProject)
                }
            } else {
                let guess = normalized.last ?? text
                let display =
                    AgentHistoryPath.isPath(guess, inside: root) && guess != root
                    ? String(guess.dropFirst(root.count + 1)) : guess
                attachment = AgentHandoffAttachment(path: display, status: .missing)
            }
            if seen.insert(attachment.path).inserted { result.append(attachment) }
        }
        return result
    }
}
