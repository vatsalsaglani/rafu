import Foundation
import Testing

@testable import RafuApp

/// Drift guard for `docs/references/conductor-cli-capability-matrix.md`.
/// The matrix documents what each CLI can do AND what Rafu actually wires;
/// these pin the "what Rafu wires" column so the doc cannot quietly go stale.
@Test("Every roster adapter is reachable and declares its discovery honestly")
func rosterDeclaresCapabilitiesConsistently() async {
    for id in ConductorCLIID.allCases {
        let adapter = ConductorAdapterRegistry.adapter(for: id)
        #expect(adapter != nil, "\(id) has no adapter")
        guard let adapter else { continue }

        // An adapter claiming discovery must actually return something for a
        // caller; one that does not must not pretend otherwise. Both are
        // rows in the matrix's "Model listing" line.
        let discovered = await adapter.discoverModels()
        if adapter.supportsModelDiscovery {
            #expect(discovered != nil, "\(id) claims discovery but returned nil")
        }
        // Curated entries are the universal fallback and must never be empty
        // for a roster CLI — an empty picker with no custom entry is a
        // dead end for the user.
        #expect(!adapter.curatedModels().isEmpty, "\(id) offers no models at all")
    }
}

@Test("Reasoning effort is genuinely unwired — the role model carries no field for it")
func reasoningEffortIsNotYetWired() {
    // The matrix records this as a KNOWN GAP: Claude Code (`--effort`) and
    // Cline (`--thinking`) both accept an effort level and Rafu passes
    // neither. If someone adds the field, this test fails and the matrix
    // must be updated in the same change rather than drifting.
    let role = ConductorAgentDefinition(
        name: "advisor",
        provider: .claudeCode,
        model: "",
        autonomy: .readOnly,
        handoffArtifact: "brief.md",
        promptBody: "body")
    let mirror = Mirror(reflecting: role)
    let fields = Set(mirror.children.compactMap(\.label))
    #expect(fields == ["name", "provider", "model", "autonomy", "handoffArtifact", "promptBody"])
    #expect(!fields.contains("effort"))
    #expect(!fields.contains("thinking"))
}

@Test("No adapter smuggles a reasoning-effort or resume flag into its argv")
func noAdapterPassesUnwiredFlags() {
    // Guards the matrix's honesty: an adapter must not pass an effort or
    // session flag that nothing in Rafu can actually set, because the value
    // would be invented rather than chosen by the user.
    let forbidden = ["--effort", "--thinking", "--resume", "--continue", "--session-id", "--fork"]
    for id in ConductorCLIID.allCases {
        guard let adapter = ConductorAdapterRegistry.adapter(for: id) else { continue }
        for autonomy in ConductorAutonomy.allCases {
            let invocation = adapter.invocation(
                prompt: "do the thing",
                model: "some/model",
                autonomy: autonomy,
                workingDirectory: URL(fileURLWithPath: "/tmp/work"),
                runDirectory: URL(fileURLWithPath: "/tmp/run"),
                handoffDirectory: URL(fileURLWithPath: "/tmp/run/handoff"))
            for flag in forbidden {
                #expect(
                    !invocation.arguments.contains(flag),
                    "\(id) passes \(flag), which nothing in Rafu can set")
            }
        }
    }
}

@Test("Codex is discovered inside ChatGPT.app, which is never on PATH")
func codexIsFoundInsideChatGPTApp() {
    // Codex ships bundled in ChatGPT.app rather than on PATH, so `which
    // codex` fails on a machine where Codex works fine. The candidate list
    // must keep that location or Codex reads as "not found" (the same class
    // of bug as Cline under nvm).
    let candidates = CodexAdapter.standardExecutableURLsForTesting(
        homeDirectory: URL(fileURLWithPath: "/Users/fixture"))
    #expect(
        candidates.contains {
            $0.path == "/Applications/ChatGPT.app/Contents/Resources/codex"
        })
}
