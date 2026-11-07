import CryptoKit
import Foundation
import JSONRenderCore

/// The saved form of a generated view's state (pure, unit-tested).
///
/// Never persisted: a key that starts with `_` at any depth; every state path
/// a secret prop binds (`ComponentDefinition.secretProps`, for example the
/// standard Input's `value`); `transientPaths`; one value whose canonical JSON
/// is over `valueCap`. Over `cap`, the newest changes go back to their seed
/// value first; if it still does not fit, nothing is saved. Journal lines carry
/// paths and counts only, never values.
nonisolated enum GeneratedViewStatePersistence {
    struct Output: Equatable, Sendable {
        /// `nil` when nothing could be saved.
        var state: CanvasGeneratedViewState?
        /// Some values were not saved because of the caps.
        var notSaved: Bool
        var journal: [String]
    }

    /// One secret binding: a state pointer, or a field of every row of a
    /// repeated array (`$bindItem`).
    enum SecretPath: Hashable, Sendable {
        case pointer(JSONPointer)
        case rows(base: JSONPointer, field: JSONPointer)
    }

    // MARK: Canonical text and versions

    /// Sorted keys, no escaped slashes. The same value always gives the same text.
    static func canonicalText(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// SHA-256 (lowercase hex) of the canonical spec without its `state`.
    static func specVersion(of spec: Spec) -> String {
        let bare = Spec(root: spec.root, elements: spec.elements, state: nil)
        let text = canonicalText(bare) ?? ""
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// The saved state as a value, or `nil` when it does not apply to this
    /// spec and catalog (the view changed) or does not decode.
    static func applicableState(
        _ saved: CanvasGeneratedViewState?, specVersion: String, catalogVersion: String
    ) -> JSONRenderCore.JSONValue? {
        guard let saved, saved.specVersion == specVersion,
            saved.catalogVersion == catalogVersion,
            let value = try? JSONDecoder().decode(
                JSONRenderCore.JSONValue.self, from: Data(saved.stateJSON.utf8)),
            case .object = value
        else { return nil }
        return value
    }

    // MARK: Secret paths

    /// Every state path that a secret prop of an element binds.
    static func secretPaths(in spec: Spec, secretProps: [String: [String]]) -> Set<SecretPath> {
        var parents: [String: String] = [:]
        for (id, element) in spec.elements {
            for child in element.children ?? [] { parents[child] = id }
            for ids in (element.slots ?? [:]).values { for child in ids { parents[child] = id } }
        }
        var result: Set<SecretPath> = []
        for (id, element) in spec.elements {
            guard let names = secretProps[element.type], !names.isEmpty else { continue }
            for name in names {
                guard case .object(let members)? = element.props[name] else { continue }
                if case .string(let raw)? = members["$bindState"] {
                    result.insert(.pointer(pointer(raw)))
                } else if case .string(let field)? = members["$bindItem"] {
                    result.insert(rowPath(of: id, field: field, spec: spec, parents: parents))
                }
            }
        }
        return result
    }

    /// The rows a `$bindItem` writes. A nested repeat (an `$item` state path)
    /// cannot name one array, so the whole outermost repeated array is treated
    /// as secret: losing it is safer than saving a secret.
    private static func rowPath(
        of id: String, field: String, spec: Spec, parents: [String: String]
    ) -> SecretPath {
        var current: String? = id
        var nearest: RepeatStatePath?
        var outermostAbsolute: JSONPointer?
        var steps = 0
        while let element = current.flatMap({ spec.elements[$0] }), steps < 256 {
            if let path = element.repeat?.statePath {
                if nearest == nil { nearest = path }
                if case .absolute(let raw) = path { outermostAbsolute = pointer(raw) }
            }
            current = current.flatMap { parents[$0] }
            steps += 1
        }
        if case .absolute(let raw)? = nearest {
            return .rows(base: pointer(raw), field: pointer("/" + field))
        }
        return .pointer(outermostAbsolute ?? .root)
    }

    private static func pointer(_ raw: String) -> JSONPointer {
        (try? JSONPointer(raw)) ?? JSONPointer(stringLiteral: raw)
    }

    /// The secret props of every component type in `catalog`.
    static func secretProps(of catalog: Catalog) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for definition in catalog.components where !definition.secretProps.isEmpty {
            result[definition.name] = definition.secretProps
        }
        return result
    }

    // MARK: Snapshot

    static func snapshot(
        state: JSONRenderCore.JSONValue, changedNewestLast: [JSONPointer], spec: Spec,
        secretProps: [String: [String]], transientPaths: Set<JSONPointer> = [],
        catalogVersion: String, cap: Int = CanvasLimits.generatedViewStateBytes,
        valueCap: Int = CanvasLimits.generatedViewStateValueBytes, now: Date = Date()
    ) -> Output {
        var journal: [String] = []
        var value = withoutUnderscoreKeys(state)
        // Secrets go first, so a secret never takes space from another value.
        let secrets = secretPaths(in: spec, secretProps: secretProps)
        var removedSecrets = 0
        for secret in secrets {
            switch secret {
            case .pointer(let pointer):
                if pointer.isRoot {
                    value = .object([:])
                    removedSecrets += 1
                } else if value.remove(at: pointer) {
                    removedSecrets += 1
                }
            case .rows(let base, let field):
                guard case .array(var rows)? = value.value(at: base) else { continue }
                for index in rows.indices {
                    if rows[index].remove(at: field) { removedSecrets += 1 }
                }
                _ = value.set(.array(rows), at: base)
            }
        }
        if removedSecrets > 0 { journal.append("secret values not saved: \(removedSecrets)") }
        for pointer in transientPaths { _ = value.remove(at: pointer) }
        var dropped: [String] = []
        value = withoutLargeValues(value, cap: valueCap, path: "", dropped: &dropped)
        for path in dropped.prefix(4) {
            journal.append(line("dropped \(path): value over \(valueCap / 1_024) KiB"))
        }
        let seed = withoutUnderscoreKeys(spec.state ?? .object([:]))
        var text = canonicalText(value) ?? "{}"
        var notSaved = !dropped.isEmpty
        if text.utf8.count > cap {
            var reverted = 0
            for pointer in changedNewestLast.reversed() where !pointer.isRoot {
                if let original = seed.value(at: pointer) {
                    _ = value.set(original, at: pointer)
                } else {
                    _ = value.remove(at: pointer)
                }
                reverted += 1
                text = canonicalText(value) ?? "{}"
                if text.utf8.count <= cap { break }
            }
            notSaved = true
            journal.append("state over \(cap / 1_024) KiB: \(reverted) values not saved")
            guard text.utf8.count <= cap else {
                return Output(state: nil, notSaved: true, journal: journal)
            }
        }
        let saved = CanvasGeneratedViewState(
            specVersion: specVersion(of: spec), catalogVersion: catalogVersion, savedAt: now,
            stateJSON: text)
        return Output(state: saved, notSaved: notSaved, journal: journal)
    }

    /// The value without any object key that starts with `_`, at any depth.
    static func withoutUnderscoreKeys(_ value: JSONRenderCore.JSONValue) -> JSONRenderCore.JSONValue
    {
        switch value {
        case .object(let members):
            var kept: [String: JSONRenderCore.JSONValue] = [:]
            for (key, item) in members where !key.hasPrefix("_") {
                kept[key] = withoutUnderscoreKeys(item)
            }
            return .object(kept)
        case .array(let items):
            return .array(items.map(withoutUnderscoreKeys))
        default:
            return value
        }
    }

    /// Drops scalars (and empty containers) whose canonical JSON is over `cap`
    /// bytes. Containers keep their small members; the total cap handles them.
    private static func withoutLargeValues(
        _ value: JSONRenderCore.JSONValue, cap: Int, path: String, dropped: inout [String]
    ) -> JSONRenderCore.JSONValue {
        switch value {
        case .object(let members):
            var kept: [String: JSONRenderCore.JSONValue] = [:]
            for key in members.keys.sorted() {
                guard let item = members[key] else { continue }
                let child = path + "/" + escape(key)
                if isLargeScalar(item, cap: cap) {
                    dropped.append(child)
                } else {
                    kept[key] = withoutLargeValues(item, cap: cap, path: child, dropped: &dropped)
                }
            }
            return .object(kept)
        case .array(let items):
            var kept: [JSONRenderCore.JSONValue] = []
            for (index, item) in items.enumerated() {
                let child = path + "/\(index)"
                if isLargeScalar(item, cap: cap) {
                    dropped.append(child)
                    kept.append(.null)
                } else {
                    kept.append(withoutLargeValues(item, cap: cap, path: child, dropped: &dropped))
                }
            }
            return .array(kept)
        default:
            return value
        }
    }

    private static func isLargeScalar(_ value: JSONRenderCore.JSONValue, cap: Int) -> Bool {
        switch value {
        case .object, .array: return false
        default: return (canonicalText(value)?.utf8.count ?? 0) > cap
        }
    }

    private static func escape(_ token: String) -> String {
        token.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
    }

    private static func line(_ text: String) -> String {
        guard text.utf8.count > 160 else { return text }
        return String(text.prefix(150)) + "…"
    }
}
