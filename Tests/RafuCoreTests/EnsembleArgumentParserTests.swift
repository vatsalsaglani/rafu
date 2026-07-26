import Foundation
import Testing

@testable import RafuCore

@Suite("Ensemble argument parser")
struct EnsembleArgumentParserTests {
    private let parser = EnsembleArgumentParser()

    @Test("Help forms are accepted")
    func help() throws {
        #expect(try parser.parse([]) == .help)
        #expect(try parser.parse(["help"]) == .help)
        #expect(try parser.parse(["--help"]) == .help)
        #expect(try parser.parse(["-h"]) == .help)
    }

    @Test("Status accepts run filters and every flag")
    func status() throws {
        #expect(
            try parser.parse(["status"])
                == .status(runIDs: [], tree: false, sinceCursor: nil, json: false)
        )
        #expect(
            try parser.parse(["status", "run-a", "--tree", "--since", "42", "run-b", "--json"])
                == .status(
                    runIDs: ["run-a", "run-b"],
                    tree: true,
                    sinceCursor: 42,
                    json: true
                )
        )
    }

    @Test("Run accepts the complete flag matrix and both role override forms")
    func run() throws {
        #expect(
            try parser.parse([
                "run", "ship", "--role", "reviewer=codex:gpt-5.3-codex",
                "--role", "writer=claude-code", "--prompt", "Ship it",
                "--artifact", "brief.md", "--artifact", "spec.md",
                "--base", "main", "--label", "Release prep", "--json",
            ])
                == .run(
                    workflow: "ship",
                    roleOverrides: [
                        EnsembleRoleOverride(
                            name: "reviewer",
                            provider: "codex",
                            model: "gpt-5.3-codex"
                        ),
                        EnsembleRoleOverride(
                            name: "writer",
                            provider: "claude-code",
                            model: nil
                        ),
                    ],
                    prompt: "Ship it",
                    artifacts: ["brief.md", "spec.md"],
                    baseReference: "main",
                    label: "Release prep",
                    json: true
                )
        )
        #expect(throws: EnsembleArgumentError.missingArgument("<workflow>")) {
            try parser.parse(["run", "--json"])
        }
        #expect(
            throws: EnsembleArgumentError.invalidValue(
                option: "--role",
                value: "reviewer=codex:"
            )
        ) {
            try parser.parse(["run", "ship", "--role", "reviewer=codex:"])
        }
    }

    @Test("Abort, note, and grant parse their bounded forms")
    func mutatingVerbs() throws {
        #expect(try parser.parse(["abort", "run-a"]) == .abort(runID: "run-a"))
        #expect(
            try parser.parse(["note", "run-a", "Check the diff"])
                == .note(runID: "run-a", text: "Check the diff")
        )
        #expect(try parser.parse(["grant"]) == .grant(json: false))
        #expect(try parser.parse(["grant", "--json"]) == .grant(json: true))
        #expect(
            throws: EnsembleArgumentError.valueTooLong(
                option: "<text>",
                maximumCharacters: 1_000
            )
        ) {
            try parser.parse(["note", "run-a", String(repeating: "x", count: 1_001)])
        }
    }

    @Test("Artifact requires one run and a nonnegative step")
    func artifact() throws {
        #expect(
            try parser.parse(["artifact", "run-a", "2", "--json"])
                == .artifact(runID: "run-a", stepIndex: 2, json: true)
        )
        #expect(throws: EnsembleArgumentError.missingArgument("<run>")) {
            try parser.parse(["artifact"])
        }
        #expect(throws: EnsembleArgumentError.missingArgument("<step>")) {
            try parser.parse(["artifact", "run-a"])
        }
        #expect(
            throws: EnsembleArgumentError.invalidValue(option: "<step>", value: "-1")
        ) {
            try parser.parse(["artifact", "run-a", "-1"])
        }
        #expect(throws: EnsembleArgumentError.unexpectedArgument("extra")) {
            try parser.parse(["artifact", "run-a", "0", "extra"])
        }
    }

    @Test("Await accepts all flags and repeated requested states")
    func awaitVerb() throws {
        #expect(
            try parser.parse([
                "await", "run-a", "run-b", "--state", "completed",
                "--state", "failed", "--any", "--timeout", "1.5", "--json",
            ])
                == .await(
                    runIDs: ["run-a", "run-b"],
                    states: [.completed, .failed],
                    any: true,
                    timeout: 1.5,
                    json: true
                )
        )
        #expect(throws: EnsembleArgumentError.missingArgument("<run>")) {
            try parser.parse(["await", "--state", "completed"])
        }
        #expect(throws: EnsembleArgumentError.missingValue("--state")) {
            try parser.parse(["await", "run-a"])
        }
    }

    @Test(
        "Options requiring values never consume another option",
        arguments: [
            (["status", "--since", "--json"], "--since"),
            (["await", "run", "--state", "--any"], "--state"),
            (["await", "run", "--state", "running", "--timeout", "--json"], "--timeout"),
            (["run", "ship", "--role", "--json"], "--role"),
            (["run", "ship", "--prompt", "--json"], "--prompt"),
            (["run", "ship", "--artifact", "--json"], "--artifact"),
        ]
    )
    func valuesDoNotConsumeOptions(arguments: [String], option: String) {
        #expect(throws: EnsembleArgumentError.missingValue(option)) {
            try parser.parse(arguments)
        }
    }

    @Test("Unknown verbs, options, and states are typed usage failures")
    func typedFailures() {
        #expect(throws: EnsembleArgumentError.unknownVerb("launch")) {
            try parser.parse(["launch"])
        }
        #expect(throws: EnsembleArgumentError.unknownOption("--future")) {
            try parser.parse(["status", "--future"])
        }
        #expect(throws: EnsembleArgumentError.unknownState("done")) {
            try parser.parse(["await", "run", "--state", "done"])
        }
        #expect(
            throws: EnsembleArgumentError.invalidValue(option: "--timeout", value: "0")
        ) {
            try parser.parse(["await", "run", "--state", "running", "--timeout", "0"])
        }
    }

    @Test("Duplicate singleton flags are rejected")
    func duplicateFlags() {
        #expect(throws: EnsembleArgumentError.duplicateOption("--tree")) {
            try parser.parse(["status", "--tree", "--tree"])
        }
        #expect(throws: EnsembleArgumentError.duplicateOption("--json")) {
            try parser.parse(["artifact", "run", "0", "--json", "--json"])
        }
        #expect(throws: EnsembleArgumentError.duplicateOption("--timeout")) {
            try parser.parse([
                "await", "run", "--state", "running", "--timeout", "1", "--timeout", "2",
            ])
        }
    }
}

@Suite("Ensemble subcommand collision gate")
struct EnsembleSubcommandGateTests {
    @Test("Reserved word with a local entry is a strict collision")
    func collision() {
        #expect(
            EnsembleSubcommandGate.classify(
                firstArgument: "ensemble",
                hasFilesystemEntry: true
            ) == .collision
        )
    }

    @Test("Reserved word without a local entry is the subcommand")
    func subcommand() {
        #expect(
            EnsembleSubcommandGate.classify(
                firstArgument: "ensemble",
                hasFilesystemEntry: false
            ) == .subcommand
        )
    }

    @Test("Explicit relative path and all other arguments remain launcher paths")
    func paths() {
        for argument in ["./ensemble", "/tmp/ensemble", ".", nil] as [String?] {
            #expect(
                EnsembleSubcommandGate.classify(
                    firstArgument: argument,
                    hasFilesystemEntry: true
                ) == .path
            )
        }
    }
}
