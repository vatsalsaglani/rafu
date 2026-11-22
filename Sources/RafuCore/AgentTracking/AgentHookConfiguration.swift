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

/// Which of Rafu's hook entries a change is about.
public enum AgentHookScope: String, Equatable, Sendable {
    /// The activity entries: one per event, a 1 s timeout, no output.
    case activity
    /// The opt-in Claude Code answer entry: one `PermissionRequest` entry
    /// whose helper waits for an answer from Up next
    /// (`AgentAnswerChannel.hookTimeoutSeconds`).
    case answers
}

/// A reviewed change to one provider's hook configuration. `after` is the
/// whole new file; `preview` is the exact Rafu entries added or removed.
public struct AgentHookChange: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let provider: AgentHookProvider
    public let scope: AgentHookScope
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
///
/// Claude Code can also have a second, opt-in `PermissionRequest` entry: the
/// answer entry (`scope: .answers`), whose command ends with `answerFlag`.
/// The activity Connect and the "connected" test never count or replace it.
/// Disconnecting the activity hooks removes it too, because without them
/// Rafu does not drain the spool; the answer Disconnect removes only it.
public enum AgentHookConfiguration {
    public static let maximumConfigurationBytes = 1_048_576
    /// Seconds. The helper exits within 1 s on its own alarm.
    public static let hookTimeoutSeconds = 1
    /// The last helper argument of the answer entry.
    public static let answerFlag = "--answer"
    /// The one event that has an answer entry.
    public static let answerEventName = "PermissionRequest"

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

    /// `'<helper>' claude '<spool>' --answer`: the answer entry's command.
    public static func answerCommand(helper: URL, spool: URL) -> String {
        command(helper: helper, provider: .claude, spool: spool) + " " + answerFlag
    }

    /// A command that runs Rafu's helper at `helper`, in either mode.
    public static func isRafuCommand(_ command: String, helper: URL) -> Bool {
        command.hasPrefix(shellQuoted(helper.path) + " ")
    }

    /// A Rafu command that runs the helper's answer mode.
    public static func isAnswerCommand(_ command: String, helper: URL) -> Bool {
        isRafuCommand(command, helper: helper) && command.hasSuffix(" " + answerFlag)
    }

    /// The events that `scope` writes for `provider`. Only Claude Code has an
    /// answer entry.
    public static func eventNames(provider: AgentHookProvider, scope: AgentHookScope)
        -> [String]
    {
        switch scope {
        case .activity: provider.hookEventNames
        case .answers: provider == .claude ? [answerEventName] : []
        }
    }

    /// Whether `existing` has a Rafu activity entry for every event of
    /// `provider`. The answer entry does not count.
    public static func isConnected(
        provider: AgentHookProvider, existing: Data?, helper: URL
    ) -> Bool {
        hasRafuEntries(provider: provider, scope: .activity, existing: existing, helper: helper)
    }

    /// Whether `existing` has Claude Code's answer entry.
    public static func isAnswerConnected(existing: Data?, helper: URL) -> Bool {
        hasRafuEntries(provider: .claude, scope: .answers, existing: existing, helper: helper)
    }

    /// Whether any hook command in `existing` runs `helper`, in activity or
    /// answer mode. Unlike `isConnected`, it needs no entry for every event,
    /// so a file written by an older Rafu still counts. `false` for a missing
    /// or unreadable file.
    public static func referencesHelper(
        provider: AgentHookProvider, existing: Data?, helper: URL
    ) -> Bool {
        guard let existing, let document = try? parse(existing),
            let hooks = document["hooks"] as? [String: Any]
        else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                commands(in: entry, provider: provider).contains {
                    isRafuCommand($0, helper: helper)
                }
            }
        }
    }

    private static func hasRafuEntries(
        provider: AgentHookProvider, scope: AgentHookScope, existing: Data?, helper: URL
    ) -> Bool {
        let events = eventNames(provider: provider, scope: scope)
        guard !events.isEmpty, let existing, let document = try? parse(existing),
            let hooks = document["hooks"] as? [String: Any]
        else { return false }
        return events.allSatisfy { event in
            guard let entries = hooks[event] as? [[String: Any]] else { return false }
            return entries.contains { entry in
                commands(in: entry, provider: provider).contains {
                    belongs($0, to: scope, helper: helper)
                }
            }
        }
    }

    /// Whether `command` is a Rafu command of `scope`.
    private static func belongs(_ command: String, to scope: AgentHookScope, helper: URL)
        -> Bool
    {
        switch scope {
        case .activity:
            isRafuCommand(command, helper: helper) && !isAnswerCommand(command, helper: helper)
        case .answers: isAnswerCommand(command, helper: helper)
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
        scope: AgentHookScope = .activity,
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
        let hookCommand =
            scope == .answers
            ? answerCommand(helper: helper, spool: spool)
            : command(helper: helper, provider: provider, spool: spool)
        let timeout =
            scope == .answers ? AgentAnswerChannel.hookTimeoutSeconds : hookTimeoutSeconds
        var changed: [String] = []
        var previewEntries: [String: [[String: Any]]] = [:]
        for event in eventNames(provider: provider, scope: scope) {
            if let value = hooks[event], !(value is [[String: Any]]) {
                throw AgentHookConfigurationError.unexpectedStructure
            }
            var entries = hooks[event] as? [[String: Any]] ?? []
            let alreadyExact =
                !removing
                && entries.contains { entry in
                    commands(in: entry, provider: provider).contains(hookCommand)
                }
            // Disconnect drops every Rafu command of the scope for this
            // helper (the activity Disconnect also drops the answer entry);
            // Connect drops only stale ones of its own scope (an older spool
            // path) and keeps an exact entry where it is.
            var removed: [[String: Any]] = []
            entries = entries.compactMap { entry in
                let result = without(entry, provider: provider) { candidate in
                    let owned =
                        removing && scope == .activity
                        ? isRafuCommand(candidate, helper: helper)
                        : belongs(candidate, to: scope, helper: helper)
                    return owned && (removing || candidate != hookCommand)
                }
                removed += result.removed
                return result.entry
            }
            let adds = !removing && !alreadyExact
            let added = entry(command: hookCommand, provider: provider, timeout: timeout)
            if adds {
                entries.append(added)
                previewEntries[event] = [added]
            } else if removing, !removed.isEmpty {
                previewEntries[event] = removed
            }
            if !removed.isEmpty || adds { changed.append(event) }
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
            scope: scope,
            destination: destination,
            removing: removing,
            command: hookCommand,
            preview: try preview(provider: provider, entries: previewEntries),
            changedEvents: changed,
            before: existing,
            after: after + Data("\n".utf8))
    }

    /// The JSON fragment shown in the review sheet: exactly the entries that
    /// Connect adds or Disconnect removes.
    static func preview(
        provider: AgentHookProvider, entries: [String: [[String: Any]]]
    ) throws -> String {
        var fragment: [String: Any] = ["hooks": entries]
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

    private static func entry(command: String, provider: AgentHookProvider, timeout: Int)
        -> [String: Any]
    {
        if provider == .cursor { return ["command": command, "timeout": timeout] }
        return ["hooks": [["type": "command", "command": command, "timeout": timeout]]]
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
    /// `removed` holds what was dropped, in the provider's entry shape, for
    /// the review preview.
    private static func without(
        _ entry: [String: Any], provider: AgentHookProvider,
        dropping: (String) -> Bool
    ) -> (entry: [String: Any]?, removed: [[String: Any]]) {
        if provider == .cursor {
            guard let command = entry["command"] as? String, dropping(command),
                entry["type"] == nil || (entry["type"] as? String) == "command"
            else { return (entry, []) }
            return (nil, [entry])
        }
        guard let children = entry["hooks"] as? [[String: Any]] else { return (entry, []) }
        var kept: [[String: Any]] = []
        var dropped: [[String: Any]] = []
        for child in children {
            if (child["type"] as? String) == "command",
                let command = child["command"] as? String, dropping(command)
            {
                dropped.append(child)
            } else {
                kept.append(child)
            }
        }
        if dropped.isEmpty { return (entry, []) }
        let removed: [[String: Any]] = [["hooks": dropped]]
        if kept.isEmpty { return (nil, removed) }
        var copy = entry
        copy["hooks"] = kept
        return (copy, removed)
    }
}
