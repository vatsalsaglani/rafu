import Foundation

public enum AgentHookConfigurationError: Error, Equatable, Sendable {
    /// The configuration file (or its folder) is a symbolic link.
    case symlinkedConfiguration
    /// The file is not valid JSON or its top level is not an object.
    case unparseableConfiguration
    /// `hooks` or one event's list has an unexpected shape.
    case unexpectedStructure
    case configurationTooLarge
    /// The file changed between the review and the write.
    case changedSinceReview
    /// The app bundle has no hook helper to copy.
    case helperMissing
    /// A read or write failed for another reason (permissions, disk).
    case fileSystemFailure
}

/// A reviewed change to one provider's hook configuration. `after` is the
/// whole new file; `preview` is the exact Rafu entries added or removed.
public struct AgentHookChange: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: AgentHookProvider
    public let destination: URL
    public let removing: Bool
    /// The hook command, exactly as written into each entry.
    public let command: String
    public let preview: String
    /// The event names that gain (or lose) a Rafu entry.
    public let changedEvents: [String]
    public let before: Data?
    public let after: Data

    /// Nothing to write: Connect found every entry, or Disconnect found none.
    public var isNoOp: Bool { changedEvents.isEmpty }
}

/// Builds hook configuration changes for Claude Code
/// (`settings.json`), Codex (`hooks.json`), and Cursor (`hooks.json`).
///
/// The merge appends one Rafu entry per event and never removes, edits, or
/// reorders another hook. Rafu's entries are the `command` hooks whose
/// command starts with the quoted helper path, so Disconnect removes only
/// those. Keys are written sorted; array order is kept.
public enum AgentHookConfiguration {
    public static let maximumConfigurationBytes = 1_048_576
    /// Seconds. The helper exits within 1 s on its own alarm.
    public static let hookTimeoutSeconds = 1

    /// The provider's user-level hook file. Honors `CLAUDE_CONFIG_DIR` and
    /// `CODEX_HOME` as the CLIs do.
    public static func destination(
        provider: AgentHookProvider, home: URL, environment: [String: String]
    ) -> URL {
        func folder(_ key: String, _ fallback: String) -> URL {
            if let value = environment[key], value.hasPrefix("/") {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            return home.appending(path: fallback, directoryHint: .isDirectory)
        }
        switch provider {
        case .claude: return folder("CLAUDE_CONFIG_DIR", ".claude").appending(path: "settings.json")
        case .codex: return folder("CODEX_HOME", ".codex").appending(path: "hooks.json")
        case .cursor:
            return home.appending(path: ".cursor", directoryHint: .isDirectory)
                .appending(path: "hooks.json")
        }
    }

    /// POSIX single-quote quoting: safe for paths with spaces, quotes, `$`,
    /// and backticks. The provider runs the command through `/bin/sh`.
    public static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `'<helper>' <provider> '<spool>'`.
    public static func command(helper: URL, provider: AgentHookProvider, spool: URL) -> String {
        shellQuoted(helper.path) + " " + provider.rawValue + " " + shellQuoted(spool.path)
    }

    /// A command that runs Rafu's helper at `helper`.
    public static func isRafuCommand(_ command: String, helper: URL) -> Bool {
        command.hasPrefix(shellQuoted(helper.path) + " ")
    }

    /// Whether `existing` has a Rafu entry for every event of `provider`.
    public static func isConnected(
        provider: AgentHookProvider, existing: Data?, helper: URL
    ) -> Bool {
        guard let existing, let document = try? parse(existing),
            let hooks = document["hooks"] as? [String: Any]
        else { return false }
        return provider.hookEventNames.allSatisfy { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                commands(in: entry, provider: provider).contains {
                    isRafuCommand($0, helper: helper)
                }
            }
        }
    }

    /// Plans adding (or, with `removing`, deleting) Rafu's entries.
    public static func plan(
        provider: AgentHookProvider,
        destination: URL,
        existing: Data?,
        helper: URL,
        spool: URL,
        removing: Bool,
        id: UUID = UUID()
    ) throws -> AgentHookChange {
        if let existing, existing.count > maximumConfigurationBytes {
            throw AgentHookConfigurationError.configurationTooLarge
        }
        var document = try existing.map(parse) ?? [:]
        if let hooks = document["hooks"], !(hooks is [String: Any]) {
            throw AgentHookConfigurationError.unexpectedStructure
        }
        if provider == .cursor, let version = document["version"] {
            guard (version as? Int) == 1 else {
                throw AgentHookConfigurationError.unexpectedStructure
            }
        }
        var hooks = document["hooks"] as? [String: Any] ?? [:]
        let hookCommand = command(helper: helper, provider: provider, spool: spool)
        var changed: [String] = []
        for event in provider.hookEventNames {
            if let value = hooks[event], !(value is [[String: Any]]) {
                throw AgentHookConfigurationError.unexpectedStructure
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyExact =
                !removing
                && entries.contains { entry in
                    commands(in: entry, provider: provider).contains(hookCommand)
                }
            // Disconnect drops every Rafu command for this helper; Connect
            // drops only stale ones (an older spool path) and keeps an exact
            // entry where it is.
            var removedAny = false
            entries = entries.compactMap { entry in
                let result = without(entry, provider: provider) { candidate in
                    isRafuCommand(candidate, helper: helper)
                        && (removing || candidate != hookCommand)
                }
                if result.removed { removedAny = true }
                return result.entry
            }
            let adds = !removing && !alreadyExact
            if adds { entries.append(entry(command: hookCommand, provider: provider)) }
            if removedAny || adds { changed.append(event) }
            if entries.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = entries
            }
        }
        if hooks.isEmpty, removing {
            document.removeValue(forKey: "hooks")
        } else {
            document["hooks"] = hooks
        }
        if provider == .cursor, !removing { document["version"] = 1 }
        let options: JSONSerialization.WritingOptions = [
            .prettyPrinted, .sortedKeys, .withoutEscapingSlashes,
        ]
        let after = try JSONSerialization.data(withJSONObject: document, options: options)
        return AgentHookChange(
            id: id,
            provider: provider,
            destination: destination,
            removing: removing,
            command: hookCommand,
            preview: try preview(provider: provider, command: hookCommand, events: changed),
            changedEvents: changed,
            before: existing,
            after: after + Data("\n".utf8))
    }

    /// The JSON fragment shown in the review sheet: exactly the entries that
    /// Connect adds or Disconnect removes.
    static func preview(
        provider: AgentHookProvider, command: String, events: [String]
    ) throws -> String {
        var hooks: [String: Any] = [:]
        for event in events { hooks[event] = [entry(command: command, provider: provider)] }
        var fragment: [String: Any] = ["hooks": hooks]
        if provider == .cursor { fragment["version"] = 1 }
        let data = try JSONSerialization.data(
            withJSONObject: fragment,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return String(decoding: data, as: UTF8.self)
    }

    static func parse(_ data: Data) throws -> [String: Any] {
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentHookConfigurationError.unparseableConfiguration
        }
        return object
    }

    private static func entry(command: String, provider: AgentHookProvider) -> [String: Any] {
        if provider == .cursor { return ["command": command, "timeout": hookTimeoutSeconds] }
        return [
            "hooks": [["type": "command", "command": command, "timeout": hookTimeoutSeconds]]
        ]
    }

    /// The command strings of one event entry.
    private static func commands(in entry: [String: Any], provider: AgentHookProvider)
        -> [String]
    {
        if provider == .cursor {
            return (entry["command"] as? String).map { [$0] } ?? []
        }
        let children = entry["hooks"] as? [[String: Any]] ?? []
        return children.compactMap { child in
            (child["type"] as? String) == "command" ? child["command"] as? String : nil
        }
    }

    /// `entry` without the command hooks `dropping` selects; `nil` when no
    /// hook is left in it. An entry with no matching hook comes back as is.
    private static func without(
        _ entry: [String: Any], provider: AgentHookProvider,
        dropping: (String) -> Bool
    ) -> (entry: [String: Any]?, removed: Bool) {
        if provider == .cursor {
            guard let command = entry["command"] as? String, dropping(command),
                entry["type"] == nil || (entry["type"] as? String) == "command"
            else { return (entry, false) }
            return (nil, true)
        }
        guard let children = entry["hooks"] as? [[String: Any]] else { return (entry, false) }
        let kept = children.filter { child in
            guard (child["type"] as? String) == "command",
                let command = child["command"] as? String
            else { return true }
            return !dropping(command)
        }
        if kept.count == children.count { return (entry, false) }
        if kept.isEmpty { return (nil, true) }
        var copy = entry
        copy["hooks"] = kept
        return (copy, true)
    }
}
