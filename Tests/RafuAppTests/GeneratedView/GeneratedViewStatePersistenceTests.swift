import Foundation
import JSONRenderCore
import Testing

@testable import RafuApp

@Suite("Generated view state persistence")
struct GeneratedViewStatePersistenceTests {
    typealias Persistence = GeneratedViewStatePersistence
    typealias Value = JSONRenderCore.JSONValue

    static let secrets = ["Input": ["value"]]

    private func save(
        _ state: Value, spec: Spec, changed: [JSONPointer] = [], cap: Int = 64 * 1_024
    ) -> Persistence.Output {
        Persistence.snapshot(
            state: state, changedNewestLast: changed, spec: spec, secretProps: Self.secrets,
            catalogVersion: "test", cap: cap)
    }

    @Test("Keys that start with _ are never saved, at the top level or deeper")
    func underscoreKeys() throws {
        let spec = try GeneratedViewFixtures.spec(GeneratedViewFixtures.textSpec)
        let state: Value = [
            "_draft": "private note", "a": ["b": ["_c": "deep secret", "d": 2]], "keep": true,
        ]
        let text = try #require(save(state, spec: spec).state?.stateJSON)
        #expect(!text.contains("_draft") && !text.contains("private note"))
        #expect(!text.contains("_c") && !text.contains("deep secret"))
        #expect(text.contains("\"d\":2") && text.contains("\"keep\":true"))
    }

    @Test("A password Input's bound value is never saved")
    func secretBinding() throws {
        let spec = try GeneratedViewFixtures.spec(GeneratedViewFixtures.formSpec)
        let output = save(["on": true, "pw": "hunter2"], spec: spec)
        let text = try #require(output.state?.stateJSON)
        #expect(!text.contains("hunter2") && !text.contains("\"pw\""))
        #expect(text.contains("\"on\":true"))
        #expect(output.journal.contains { $0.hasPrefix("secret values not saved") })
        #expect(output.journal.allSatisfy { !$0.contains("hunter2") })
    }

    @Test("The Rafu catalog marks the standard Input value as secret")
    func catalogSecretProps() {
        let props = Persistence.secretProps(of: RafuCatalog.rafu)
        #expect(props["Input"]?.contains("value") == true)
    }

    @Test("A secret bound with $bindItem drops that field in every row")
    func secretRows() throws {
        let spec = try GeneratedViewFixtures.spec(
            #"""
            {"root":"l","elements":{
              "l":{"type":"Stack","props":{},"children":["i"],"repeat":{"statePath":"/rows"}},
              "i":{"type":"Input","props":{"label":"T","name":"t","value":{"$bindItem":"token"}}}
            },"state":{"rows":[]}}
            """#)
        let paths = Persistence.secretPaths(in: spec, secretProps: Self.secrets)
        #expect(paths == [.rows(base: "/rows", field: "/token")])
        let state: Value = ["rows": [["token": "abc123", "name": "one"], ["token": "def456"]]]
        let text = try #require(save(state, spec: spec).state?.stateJSON)
        #expect(!text.contains("abc123") && !text.contains("def456"))
        #expect(text.contains("one"))
    }

    @Test("A value over 4 KiB is dropped and the journal names its path")
    func largeValue() throws {
        let spec = try GeneratedViewFixtures.spec(GeneratedViewFixtures.textSpec)
        let big = String(repeating: "x", count: 5 * 1_024)
        let output = save(["big": .string(big), "small": "ok"], spec: spec)
        let text = try #require(output.state?.stateJSON)
        #expect(!text.contains("xxxx"))
        #expect(text.contains("small"))
        #expect(output.notSaved)
        #expect(output.journal.contains("dropped /big: value over 4 KiB"))
    }

    @Test("A state over 64 KiB loses its newest changes first and says so")
    func totalCap() throws {
        let spec = try GeneratedViewFixtures.spec(GeneratedViewFixtures.textSpec)
        // Seven arrays of about 10 KiB each: about 70 KiB in all.
        let chunk = Value.array(
            (0..<100).map { _ in .string(String(repeating: "y", count: 98)) })
        var members: [String: Value] = [:]
        let keys = (0..<7).map { "k\($0)" }
        for key in keys { members[key] = chunk }
        let changed = keys.map { JSONPointer(stringLiteral: "/" + $0) }
        let output = save(.object(members), spec: spec, changed: changed)
        let text = try #require(output.state?.stateJSON)
        #expect(text.utf8.count <= 64 * 1_024)
        #expect(output.notSaved)
        #expect(text.contains("\"k0\"") && !text.contains("\"k6\""))
        #expect(output.journal.contains { $0.hasPrefix("state over 64 KiB") })
    }

    @Test("A state that cannot fit is not saved at all")
    func nothingFits() throws {
        let spec = try GeneratedViewFixtures.spec(GeneratedViewFixtures.textSpec)
        let output = save(["a": "1234567890"], spec: spec, cap: 4)
        #expect(output.state == nil)
        #expect(output.notSaved)
    }

    @Test("The spec version ignores key order and the spec's state")
    func specVersion() throws {
        let one = try GeneratedViewFixtures.spec(
            #"{"root":"r","elements":{"r":{"type":"Text","props":{"text":"a","variant":"body"}}},"state":{"n":1}}"#
        )
        let two = try GeneratedViewFixtures.spec(
            #"{"elements":{"r":{"props":{"variant":"body","text":"a"},"type":"Text"}},"root":"r","state":{"n":2}}"#
        )
        let other = try GeneratedViewFixtures.spec(GeneratedViewFixtures.otherSpec)
        let version = Persistence.specVersion(of: one)
        #expect(version.count == 64 && version.allSatisfy(\.isHexDigit))
        #expect(version == Persistence.specVersion(of: two))
        #expect(version != Persistence.specVersion(of: other))
    }

    @Test("Saved state applies only when the spec and catalog versions match")
    func applicability() throws {
        let spec = try GeneratedViewFixtures.spec(GeneratedViewFixtures.formSpec)
        let saved = try #require(save(["on": true], spec: spec).state)
        let version = Persistence.specVersion(of: spec)
        #expect(
            Persistence.applicableState(saved, specVersion: version, catalogVersion: "test")
                == ["on": true])
        #expect(
            Persistence.applicableState(saved, specVersion: version, catalogVersion: "other")
                == nil)
        #expect(
            Persistence.applicableState(
                saved, specVersion: String(repeating: "0", count: 64), catalogVersion: "test")
                == nil)
    }
}
