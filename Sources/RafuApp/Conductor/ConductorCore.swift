import Foundation
import SwiftTerm

/// The Conductor contract surface (ADR 0018, conductor/C0-shim.md): every
/// later phase (C1–C7) compiles against the names in this file verbatim —
/// treat them as a binding, additive-only surface. `ConductorAdapterRegistry`
/// lists the seven roster adapters; `ConductorCLIAdapter` is the one seam a
/// vendor CLI is reached through, and no view or engine ever switches on
/// `ConductorCLIID` directly.
///
/// Every type here is a pure value type declared `nonisolated` directly in
/// its PRIMARY declaration (never a bare `extension`) — `RafuApp`'s
/// `.defaultIsolation(MainActor.self)` does not propagate `nonisolated` into
/// a later `extension` block, which would otherwise silently become
/// `@MainActor` and trap (`SIGTRAP`) the first time it ran off-main (see
/// `docs/references/nonisolated-extension-isolation-trap.md`, and
/// `UsageProviderCore.swift` for the established pattern this file follows).

// MARK: - Identity

/// The supported agent-CLI roster (conductor/README.md). Case order is
/// binding: `ConductorAdapterRegistry.all` is pinned to `allCases` order and
/// a completeness test asserts the two stay in lockstep.
///
/// Deliberately no custom `init(from:)`: unlike `WorkspaceNavigatorMode`
/// (whose tolerant decode protects window restoration), a provider this
/// build does not know is not something to silently rewrite — an agent file
/// naming an unknown provider must fail loudly, not quietly bind the role to
/// a different vendor's subscription.
nonisolated enum ConductorCLIID: String, CaseIterable, Codable, Sendable {
    case claudeCode
    case codex
    case openCode
    case cline
    case kimi
    case geminiCLI
    case cursor

    /// Human-readable label for Settings rows and role pickers. Pure — no
    /// localization table, no I/O.
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .openCode: "OpenCode"
        case .cline: "Cline"
        case .kimi: "Kimi CLI"
        case .geminiCLI: "Gemini CLI"
        case .cursor: "Cursor CLI"
        }
    }
}

/// How much a role may mutate (ADR 0018: "Rafu creates worktrees; models
/// never do"). There is deliberately NO "full access to the main checkout"
/// level — a mutating role is always confined to a Rafu-created worktree, so
/// the blast radius is bounded by construction.
nonisolated enum ConductorAutonomy: String, CaseIterable, Codable, Hashable, Sendable {
    /// Reads the checkout under the adapter's read-only sandbox mapping.
    case readOnly
    /// Writes freely, but only inside the Rafu-created `rafu/run-<id>`
    /// worktree.
    case worktreeWrite
}

/// One selectable model for a role. `source` records where the choice came
/// from so the UI can distinguish a shipped default from something the CLI
/// listed at runtime or the user typed by hand.
nonisolated struct ConductorModelChoice: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The exact string handed to the CLI (`--model <id>`), and this
    /// choice's `Identifiable` identity.
    let id: String
    let displayName: String
    let source: ModelSource

    nonisolated enum ModelSource: String, CaseIterable, Codable, Sendable {
        /// Shipped with the adapter.
        case curated
        /// Returned by the CLI's own listing command at runtime.
        case discovered
        /// Typed by the user; Rafu makes no claim it exists.
        case custom
    }

}

// MARK: - Repository-file definitions

/// A role, parsed from `.rafu/agents/<name>.md` (ADR 0018: files are the
/// source of truth — committable, diffable, shareable, usable without Rafu).
///
/// Deliberately NOT `Codable`: this type is only ever produced by
/// `ConductorAgentFileParser` from Markdown the user owns. Rafu never
/// serializes it back, so there is no second, drifting representation of a
/// role.
nonisolated struct ConductorAgentDefinition: Equatable, Sendable {
    let name: String
    let provider: ConductorCLIID
    /// Empty means "let the adapter's default model decide".
    let model: String
    let autonomy: ConductorAutonomy
    /// Relative filename this role must write into the run's handoff
    /// directory, e.g. `brief.md`. Step completion = artifact present +
    /// clean process exit.
    let handoffArtifact: String
    /// Everything after the closing frontmatter fence — the role's prompt.
    let promptBody: String
}

/// An ordered role pipeline, parsed from `.rafu/workflows/<name>.md`.
/// Not `Codable` for the same reason as `ConductorAgentDefinition`; a run
/// snapshots what it needs into `ConductorRunManifest` instead.
nonisolated struct ConductorWorkflowDefinition: Equatable, Sendable {
    let name: String
    let steps: [Step]

    /// One pipeline step. `gateAfter` is the user gate the workflow file
    /// spells `[gate]` — see `ConductorWorkflowFileParser` for the grammar.
    nonisolated struct Step: Equatable, Sendable {
        let agentName: String
        /// Artifacts produced by earlier steps that this step receives.
        let inputArtifacts: [String]
        /// Pause for explicit user review after this step completes.
        let gateAfter: Bool
        /// Whether this gate may be approved straight from a notification,
        /// without opening the artifact first (`[gate:remote]`). Defaults to
        /// `false`: remote approval is always opt-in, per workflow, by the
        /// person who wrote the file (C7).
        var safeToApproveRemotely: Bool = false
    }
}

// MARK: - Run manifest

/// Where one run step stands.
///
/// The `Codable` conformance is hand-written so the on-disk envelope is
/// stable and self-describing — `{"state":"failed","message":"…"}` rather
/// than Swift's synthesized associated-value nesting, which would rename
/// itself the moment a case gained a payload.
///
/// Decoding an UNRECOGNIZED state deliberately THROWS. This is the exact
/// opposite of `WorkspaceNavigatorMode`'s tolerant decode, and the
/// difference is intentional: a navigator mode is a UI preference worth
/// salvaging, while a run manifest is EVIDENCE. Silently downgrading an
/// unknown state to `.pending` would fabricate a claim about what an agent
/// did; an honest "this run is unreadable by this build" error is strictly
/// better.
nonisolated enum RunStepStatus: Codable, Equatable, Sendable {
    case pending
    case running
    case awaitingGate
    case completed
    case failed(String)
    case aborted
    /// The app relaunched while this step was `.running`: its child process
    /// was NOT resurrected (ADR 0004/0014). Distinct from `.failed` because
    /// nothing went wrong with the work — the process simply outlived nothing.
    case interrupted

    private nonisolated enum CodingKeys: String, CodingKey {
        case state
        case message
    }

    private nonisolated enum State: String {
        case pending
        case running
        case awaitingGate
        case completed
        case failed
        case aborted
        case interrupted
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .state)
        guard let state = State(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .state, in: container,
                debugDescription: "Unrecognized run step state \"\(raw)\".")
        }
        switch state {
        case .pending: self = .pending
        case .running: self = .running
        case .awaitingGate: self = .awaitingGate
        case .completed: self = .completed
        case .failed: self = .failed(try container.decode(String.self, forKey: .message))
        case .aborted: self = .aborted
        case .interrupted: self = .interrupted
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pending: try container.encode(State.pending.rawValue, forKey: .state)
        case .running: try container.encode(State.running.rawValue, forKey: .state)
        case .awaitingGate: try container.encode(State.awaitingGate.rawValue, forKey: .state)
        case .completed: try container.encode(State.completed.rawValue, forKey: .state)
        case .failed(let message):
            try container.encode(State.failed.rawValue, forKey: .state)
            try container.encode(message, forKey: .message)
        case .aborted: try container.encode(State.aborted.rawValue, forKey: .state)
        case .interrupted: try container.encode(State.interrupted.rawValue, forKey: .state)
        }
    }
}

/// A run's persisted record under `.rafu/runs/<id>/manifest.json` (ADR 0018:
/// "runs are repo data, not app state"). It snapshots the workflow and the
/// resolved provider/model/adapter bindings so a run stays readable after the
/// `.rafu/` files that produced it change.
nonisolated struct ConductorRunManifest: Codable, Equatable, Sendable {
    /// Also the `.rafu/runs/<id>/` directory name — see
    /// `ConductorRunStore.isValidRunID(_:)` for the accepted shape.
    let id: String
    let workflowName: String
    /// Commit the run's worktree branched from.
    let baseCommit: String
    /// The Rafu-created worktree branch, conventionally `rafu/run-<id>`.
    let worktreeBranch: String
    let createdAt: Date
    var updatedAt: Date
    var steps: [Step]
    /// Coordinator run that started this run. Additive and optional so
    /// manifests written before the Ensemble CLI decode unchanged.
    var startedBy: String? = nil
    /// Human-readable graph label supplied by a future mutating verb.
    var label: String? = nil
    /// Set only after a later human-approved merge completes.
    var mergedAt: Date? = nil
    /// The gate currently parking this run, `nil` when none is open (C5:
    /// `ConductorWorkflowController` sets this alongside the parked step's
    /// `.awaitingGate` status; C1 single-role runs never set it — their
    /// merge gate is expressed purely through `ConductorRunState`). `var`
    /// with a default keeps this additive: the synthesized memberwise init
    /// still accepts every existing call site unchanged (a `let` with a
    /// default value is EXCLUDED from Swift's synthesized memberwise init —
    /// see `TerminalProcessSpec`'s note above — but a `var` with a default is
    /// not), and `JSONEncoder`'s default `encodeIfPresent` behavior for
    /// `Optional` properties omits a `nil` key entirely, so a C1-era
    /// manifest's on-disk shape is unaffected.
    var gate: Gate? = nil
    /// Why this run looks the way it does after an app relaunch or an external
    /// change — e.g. "the app closed while this step was running". Additive and
    /// optional so pre-C7 manifests decode unchanged; `nil` means nothing
    /// unusual happened (C7 recovery).
    var recoveryNote: String? = nil

    /// One open gate: which kind, and which step it follows (or precedes,
    /// for the terminal `.merge` gate).
    nonisolated struct Gate: Codable, Equatable, Sendable {
        nonisolated enum Kind: String, Codable, Sendable {
            case step
            case merge
        }
        let kind: Kind
        let stepIndex: Int
    }

    /// What a role resolved to at the moment the run started. Stored per
    /// step so re-reading an old manifest never depends on today's
    /// `.rafu/agents/*.md` or today's adapter build.
    nonisolated struct AgentBinding: Codable, Equatable, Sendable {
        let provider: ConductorCLIID
        let model: String
        let autonomy: ConductorAutonomy
        /// Version string the adapter probe reported, `nil` when the probe
        /// could not determine one.
        let adapterVersion: String?
    }

    nonisolated struct Step: Codable, Equatable, Sendable {
        let agentName: String
        let binding: AgentBinding
        let inputArtifacts: [String]
        let handoffArtifact: String
        let gateAfter: Bool
        var status: RunStepStatus
        var startedAt: Date?
        var finishedAt: Date?
        /// 1-based attempt number; `nil` means attempt 1 (a C1-era manifest,
        /// or a C5 step that has not yet been retried). The manifest records
        /// only the CURRENT attempt — prior attempts' evidence persists on
        /// disk under their own `-a<N>` directory, untouched.
        var attempt: Int? = nil
        /// Run-relative path to this step's evidence directory, e.g.
        /// `"steps/01-advisor-a1"`. `nil` for C1's flat single-role layout.
        var evidencePath: String? = nil
        /// Snapshotted from the workflow file's `[gate:remote]` marker so a
        /// later edit to that file cannot retroactively make an already-open
        /// gate remotely approvable. `nil` in pre-C7 manifests ⇒ not safe.
        var safeToApproveRemotely: Bool? = nil
        /// What this step's attempt cost, when metering could resolve an
        /// honest delta (ADR 0017 providers are best-effort). `nil` means "no
        /// data", never zero — a provider without metering, a step too fast to
        /// resolve, or an ambiguous reading all record nothing rather than a
        /// fabricated number (C7).
        var usage: ConductorRunUsageRecord? = nil
    }
}

// MARK: - Adapter contract

/// What a binary-discovery probe found. `installed == false` is an honest,
/// expected answer — adapters degrade rather than guess (ADR 0018).
nonisolated struct AdapterProbe: Equatable, Sendable {
    let installed: Bool
    /// ABSOLUTE path to the CLI. Never a bare command name: the terminal's
    /// base environment carries no `PATH` at all (see
    /// `TerminalProcessSpec.resolvedLaunch()`), and the curated
    /// `RafuConductorEnvironment.curatedPath` handed to the child is not
    /// guaranteed to contain wherever this CLI was actually installed.
    let executableURL: URL?
    let version: String?

    /// The "we looked and it is not here" answer every stub adapter returns.
    static let notInstalled = AdapterProbe(installed: false, executableURL: nil, version: nil)
}

/// Delegated auth status (ADR 0018: Rafu never stores, reads, copies, or
/// proxies any provider credential for inference). An adapter may check for
/// the PRESENCE of a vendor credential file and read its expiry metadata; it
/// must NEVER read a token value, and the `hint` is user-facing instruction
/// text ("run `codex login` in a terminal"), never a secret.
///
/// Deliberately NOT `Codable`: auth status is a live probe result, never
/// something Rafu persists.
nonisolated enum AdapterAuthStatus: Equatable, Sendable {
    case authenticated
    case notAuthenticated(hint: String)
    /// Rafu could not determine sign-in state. `reason` explains WHY when the
    /// adapter knows — e.g. the CLI offers no non-interactive status command —
    /// so the row can say something better than a bare shrug. `nil` means the
    /// probe simply returned nothing conclusive.
    ///
    /// Unknown NEVER blocks a run: auth status is informational, and the CLI
    /// itself remains the authority at launch time (ADR 0018 delegated auth).
    case unknown(reason: String? = nil)
}

/// One resolved child-process launch. Argument ARRAY only — never a shell
/// string (standing invariant; ADR 0018 restates it for agent CLIs).
nonisolated struct AdapterInvocation: Equatable, Sendable {
    /// Absolute path to the CLI binary.
    let executableURL: URL
    let arguments: [String]
    /// Minimal, explicit additions to the child environment; always a
    /// superset of `RafuConductorEnvironment.childEnvironment(...)`, so it
    /// always carries `RAFU_HANDOFF`, `RAFU_RUN_DIR`, and the curated
    /// `PATH`. An adapter may add what its own CLI needs; nothing is
    /// inherited from the user's environment.
    let environment: [String: String]
}

/// The one seam an external agent CLI is reached through.
///
/// Explicitly `nonisolated` on the protocol itself (mirrors
/// `UsageFetchStrategy` and the shipped `AISecretStoring`) — without it,
/// `RafuApp`'s default `MainActor` isolation would infer every requirement
/// as `@MainActor`, making conforming types unusable from the off-main probe
/// and run pipelines. This is NON-NEGOTIABLE for later phases.
nonisolated protocol ConductorCLIAdapter: Sendable {
    var id: ConductorCLIID { get }

    /// Whether this adapter is offered by default before the user has ever
    /// touched its Settings toggle. Enabling only makes the CLI SELECTABLE;
    /// nothing executes without a visible, user-initiated run (ADR 0018).
    var defaultEnabled: Bool { get }

    /// `true` when `discoverModels()` can actually list models, so Settings
    /// can decide whether to offer "Refresh models" WITHOUT performing I/O
    /// at construction. Pure — never probes.
    var supportsModelDiscovery: Bool { get }

    /// Binary path, version string, `installed`.
    func probe() async -> AdapterProbe

    /// Presence/metadata checks ONLY; never reads a token value.
    func authStatus() async -> AdapterAuthStatus

    /// Shipped defaults. MUST be pure and synchronous — Settings calls this
    /// while building its rows, before any refresh.
    func curatedModels() -> [ConductorModelChoice]

    /// `nil` when the CLI has no listing command.
    func discoverModels() async -> [ConductorModelChoice]?

    /// Maps a role invocation onto this CLI's headless mode. Pure: builds
    /// argv, never spawns.
    ///
    /// `runDirectory` and `handoffDirectory` are BOTH passed explicitly and
    /// NEITHER is derived from the other:
    ///
    /// - `runDirectory` is the run root, `.rafu/runs/<id>/` — the run's whole
    ///   evidence directory (ADR 0018: "the diff is the gate").
    /// - `handoffDirectory` is where THIS step writes its artifact.
    ///
    /// They may be the same directory (a single-step run writing straight
    /// into the run root) or the handoff may sit inside the run root
    /// (`.rafu/runs/<id>/<step>/`). Deriving one from the other by walking
    /// parents is forbidden: getting it wrong once would point
    /// `RAFU_RUN_DIR` at the SHARED `.rafu/runs/` root, where a
    /// `worktreeWrite` role could read and clobber other runs' evidence,
    /// silently and with nothing to fail.
    func invocation(
        prompt: String,
        model: String,
        autonomy: ConductorAutonomy,
        workingDirectory: URL,
        runDirectory: URL,
        handoffDirectory: URL
    ) -> AdapterInvocation
}

// MARK: - Child-process environment

/// The environment variables every Conductor child receives. Named constants
/// because adapters, the run engine, and role prompts all have to agree on
/// them verbatim.
nonisolated enum RafuConductorEnvironment {
    /// Directory the role must write its handoff artifact into.
    static let handoff = "RAFU_HANDOFF"
    /// The run's `.rafu/runs/<id>/` root.
    static let runDirectory = "RAFU_RUN_DIR"
    /// Search path for the child and anything it shells out to.
    static let path = "PATH"

    /// A CURATED search path — deliberately NOT the user's inherited
    /// `PATH`.
    ///
    /// A PTY child gets no `PATH` at all (`SwiftTerm.Terminal
    /// .getEnvironmentVariables()` omits it), and `execvp` would then fall
    /// back to `confstr(_CS_PATH)` — roughly `/usr/bin:/bin` — which reaches
    /// neither Homebrew nor a user-local bin directory. Every agent CLI on
    /// the roster is a Node/Bun program that resolves an interpreter through
    /// a shebang and then shells out to `git` and friends, so an empty
    /// search path fails the child at its first subprocess.
    ///
    /// Forwarding the user's real `PATH` would be the easy fix and the wrong
    /// one: it is unbounded, user-mutable trust reaching an agent process
    /// (ADR 0018 keeps the child environment minimal and explicit). This
    /// fixed list is auditable in a diff instead. An adapter whose probe
    /// found the CLI somewhere else may PREPEND that executable's own
    /// directory; nothing here inherits.
    ///
    /// `~/.local/bin` is included because several roster CLIs install there by
    /// default. It is the one home-relative entry, expanded from
    /// `FileManager.homeDirectoryForCurrentUser` rather than read from the
    /// environment, so it stays as auditable as the fixed entries. Version
    /// managers that resolve an interpreter through a per-version shim
    /// directory (nvm, fnm, volta) are deliberately NOT guessed at here: an
    /// adapter that probes such an install is responsible for prepending the
    /// directory its own executable needs.
    static var curatedPath: String {
        let localBin = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true).path
        return "/usr/local/bin:/opt/homebrew/bin:\(localBin):/usr/bin:/bin:/usr/sbin:/sbin"
    }

    /// Directories where Node/Bun version managers put globally installed
    /// CLIs. **DISCOVERY ONLY** — this is never handed to a child process;
    /// the child's `PATH` stays `curatedPath` plus, at most, the parent
    /// directory of the executable an adapter actually resolved (ADR 0018's
    /// minimal, explicit, non-inherited child environment).
    ///
    /// Why this exists: Rafu.app launched from Finder inherits launchd's
    /// minimal `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`) — NOT the login
    /// shell's. A CLI installed under nvm therefore resolves fine when you
    /// run `which cline` in Terminal and is invisible to the running app,
    /// which reads as a flatly wrong "Not found on this Mac".
    ///
    /// nvm keeps a directory per installed Node version, so those are
    /// enumerated newest-name-first; everything else is a single fixed
    /// directory. Nonexistent entries are dropped, so this costs one shallow
    /// directory read on a machine that uses none of them.
    static var versionManagerBinDirectories: [URL] {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser
        var directories: [URL] = []

        // nvm / nodenv / n keep one directory per installed version.
        let versioned: [(root: String, suffix: String)] = [
            (".nvm/versions/node", "bin"),
            (".fnm/node-versions", "installation/bin"),
            ("n/versions/node", "bin"),
            (".nodenv/versions", "bin"),
        ]
        for entry in versioned {
            let root = home.appendingPathComponent(entry.root, isDirectory: true)
            guard
                let children = try? manager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil)
            else { continue }
            for child in children.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }) {
                directories.append(child.appendingPathComponent(entry.suffix, isDirectory: true))
            }
        }

        // Single fixed directories.
        for fixed in [
            ".volta/bin",
            ".asdf/shims",
            ".bun/bin",
            ".deno/bin",
            ".config/yarn/global/node_modules/.bin",
            ".yarn/bin",
            ".npm-global/bin",
        ] {
            directories.append(home.appendingPathComponent(fixed, isDirectory: true))
        }

        return directories.filter { url in
            var isDirectory: ObjCBool = false
            let exists = manager.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return exists && isDirectory.boolValue
        }
    }

    /// The search path adapters DISCOVER with: the host's own `PATH` (rich
    /// when Rafu was launched from a shell, near-useless under launchd),
    /// then the curated entries, then version-manager directories.
    /// Deduplicated, absolute components only.
    ///
    /// Deliberately distinct from `curatedPath`: widening where Rafu will
    /// LOOK for a CLI is not the same as widening what a child inherits, and
    /// only the former is safe to derive from the user's environment.
    static func discoverySearchPath(
        hostSearchPath: String = ProcessInfo.processInfo.environment[
            RafuConductorEnvironment.path] ?? ""
    ) -> String {
        var seen: Set<String> = []
        var components: [String] = []
        let candidates =
            hostSearchPath.split(separator: ":").map(String.init)
            + curatedPath.split(separator: ":").map(String.init)
            + versionManagerBinDirectories.map(\.path)
        for component in candidates
        where component.hasPrefix("/") && seen.insert(component).inserted {
            components.append(component)
        }
        return components.joined(separator: ":")
    }

    /// The minimal, explicit environment every Conductor child receives: the
    /// two `RAFU_` directories plus the curated `PATH`, and nothing
    /// inherited (ADR 0018: minimal explicit child env; no credentials are
    /// ever forwarded).
    ///
    /// Both directories are passed EXPLICITLY and neither is derived from
    /// the other — see `ConductorCLIAdapter.invocation` for why walking
    /// parent directories to find the run root is forbidden. Adapters may
    /// add keys their own CLI needs on top of these.
    static func childEnvironment(runDirectory: URL, handoffDirectory: URL) -> [String: String] {
        [
            handoff: handoffDirectory.path,
            self.runDirectory: runDirectory.path,
            path: curatedPath,
        ]
    }
}

/// The exact tuple `SwiftTerm`'s `startProcess` takes, produced by
/// `TerminalProcessSpec.resolvedLaunch()` so the mapping is testable without
/// a PTY, an `NSView`, or a spawn.
nonisolated struct TerminalLaunchArguments: Equatable, Sendable {
    let executable: String
    let arguments: [String]
    /// `"KEY=VALUE"` strings — NOT a dictionary. SwiftTerm's `startProcess`
    /// takes `[String]?`.
    let environment: [String]?
    /// `nil` for the Conductor path: `execName` exists to fake a login shell
    /// (`-zsh`), which an agent CLI must not pretend to be.
    let execName: String?
    let currentDirectory: String?
}

/// "Spawn THIS executable with THIS argv, cwd, and env under the terminal
/// PTY, labelled with a role badge" — the C0 seam that lets
/// `WorkspaceTerminalController` host an agent CLI instead of a login shell
/// (conductor/C0-shim.md). Until C1 the spec path is exercised by tests only.
nonisolated struct TerminalProcessSpec: Equatable, Sendable {
    /// ABSOLUTE path — see `resolvedLaunch()`'s note about `PATH`.
    let executableURL: URL
    let arguments: [String]
    let currentDirectoryPath: String
    /// Explicit additions merged OVER the terminal base variables.
    let environment: [String: String]
    /// Short role label ("advisor", "implementor") shown as the session's
    /// name in the terminal tab and panel row.
    let roleBadge: String
    /// How this child appears in the Resources surface — e.g.
    /// "implementor • Codex". `nil` for a plain login shell, which keeps its
    /// existing "Terminal N" naming (C7 accounting).
    let resourceAttribution: String?
    /// Where `WorkspaceTerminalController` tees this run's raw PTY output
    /// for evidence (`.rafu/runs/<id>/logs/output.log`), `nil` for a plain
    /// login shell. Deliberately UNUSED by `resolvedLaunch()` below — this
    /// stays a pure SwiftTerm launch mapping; only the terminal controller
    /// (never a shell env var or argv) consumes this URL, so it can never
    /// reach the child process or a log line.
    let outputLogURL: URL?

    /// Explicit, not synthesized: a `let` property with a default-value
    /// initializer is excluded from Swift's synthesized memberwise
    /// initializer entirely (verified against the Swift 6.2 toolchain — it
    /// is not merely optional-with-a-default, it is unreachable through any
    /// initializer), so `outputLogURL` needs this one explicit initializer
    /// to stay both immutable and settable by `ConductorRunController`.
    /// Every existing call site keeps compiling unchanged because
    /// `outputLogURL` defaults to `nil` here exactly as it would have from a
    /// synthesized init.
    init(
        executableURL: URL,
        arguments: [String],
        currentDirectoryPath: String,
        environment: [String: String],
        roleBadge: String,
        outputLogURL: URL? = nil,
        resourceAttribution: String? = nil
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.currentDirectoryPath = currentDirectoryPath
        self.environment = environment
        self.roleBadge = roleBadge
        self.outputLogURL = outputLogURL
        self.resourceAttribution = resourceAttribution
    }

    /// Pure mapping onto `SwiftTerm.LocalProcessTerminalView.startProcess`.
    /// Declared in the PRIMARY body (never a bare extension) so it stays
    /// genuinely `nonisolated`.
    ///
    /// The base variables come from `SwiftTerm.Terminal
    /// .getEnvironmentVariables()` (TERM, COLORTERM, LANG, plus LOGNAME/
    /// USER/DISPLAY/LC_TYPE/HOME when present). SwiftTerm 1.14.0
    /// deliberately OMITS `PATH` from that set, so a PTY child inherits no
    /// search path — which is exactly why `AdapterInvocation.executableURL`
    /// and `TerminalProcessSpec.executableURL` must be absolute, and why a
    /// Conductor child's `PATH` comes from
    /// `RafuConductorEnvironment.curatedPath` through the adapter's
    /// `environment` rather than from anything the terminal supplies.
    ///
    /// The result is SORTED so it is deterministic and assertable.
    func resolvedLaunch() -> TerminalLaunchArguments {
        var merged: [String: String] = [:]
        for entry in SwiftTerm.Terminal.getEnvironmentVariables() {
            guard let separator = entry.firstIndex(of: "=") else { continue }
            merged[String(entry[entry.startIndex..<separator])] = String(
                entry[entry.index(after: separator)...])
        }
        for (key, value) in environment {
            merged[key] = value
        }
        return TerminalLaunchArguments(
            executable: executableURL.path,
            arguments: arguments,
            environment: merged.map { "\($0.key)=\($0.value)" }.sorted(),
            execName: nil,
            currentDirectory: currentDirectoryPath)
    }
}
