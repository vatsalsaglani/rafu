# W0 — Shared usage-provider shim (SERIAL — merges before all fan-out)

Everything W1–W8 compiles against lands here. The names and file layout
below are BINDING — later phases reference them verbatim, so renames
after merge break eight worktrees.

## Owned paths (created/modified by W0 ONLY)

Created:
- `Sources/RafuApp/Usage/UsageProviderCore.swift` — the contract
- `Sources/RafuApp/Usage/UsageProviderRegistry.swift` — all 19 descriptors
- `Sources/RafuApp/Usage/UsageSupport.swift` — HTTP client, ISO parsing,
  compact token formatting (moved from `AgentUsage.swift`)
- `Sources/RafuApp/Usage/UsageSQLite.swift` — read-only SQLite helper
- `Sources/RafuApp/Usage/UsageStores.swift` — enable / show-in-strip /
  credential stores
- `Sources/RafuApp/Usage/Providers/<Name>Provider.swift` — ONE stub file
  per roster provider (19 files; exact basenames listed below)
- `Sources/RafuApp/Settings/UsageSettingsTab.swift` — registry-driven tab
- `Tests/RafuAppTests/Usage/UsageCoreTests.swift`, `UsageStoreTests.swift`

Modified (for the LAST time by anyone in this plan):
- `Sources/RafuApp/Settings/RafuSettingsView.swift` — add the Usage tab
- `Sources/RafuApp/Terminal/NotchCompanionModel.swift` /
  `Sources/RafuApp/Views/NotchCompanionView.swift` — tiles come from the
  registry, per the parent plan's "Multi-provider display in the notch"
  section (BINDING): resting strip never shows usage; peek panel = a
  front line of ≤4 user-ordered tiles (single muted line, defaults to
  detected local providers) + all other enabled providers behind one
  `▸ N more providers` disclosure expanding (per-peek, unpersisted) to
  a two-column grid inside the existing ScrollView; tile text
  `Name · 5h 82% · 7d 41%` (cost-only: `Name · $41.20`); ≥80% accent
  semibold, ≥95% adds `⚠` (never color alone); no icons, no
  urgency-based reordering; failed/expired tiles vanish silently (only
  Settings explains). `peekContentHeight()` gains front-line and
  expanded-grid-rows terms. Pure derivations (front-line selection from
  the show-in-strip store, overflow partition, emphasis thresholds,
  grid row math) live in a `nonisolated` policy type with headless
  tests.
- `Sources/RafuApp/Terminal/AgentUsage.swift` — existing Codex/Claude
  local parsers MIGRATE into their provider files; this file shrinks to
  whatever the companion still needs or is deleted

## The contract (implement exactly; advisor refines internals only)

```swift
nonisolated enum UsageProviderID: String, CaseIterable, Codable, Sendable {
    case claude, codex, cline, openCode, openCodeGo, cursor, antigravity,
         grokBuild, geminiCLI, kiloCode, copilot, windsurf, amp,
         factoryDroid, openRouter, kimi, warp, qwen, qoder
}

nonisolated struct UsageWindow: Equatable, Sendable {
    let label: String        // "5h" / "7d" / "monthly"
    let percent: Double?     // real % or nil
    let tokens: Int?         // token total or nil (never both fake)
    let resetsAt: Date?
}

nonisolated struct UsageSnapshot: Equatable, Sendable {
    let providerID: UsageProviderID
    let windows: [UsageWindow]   // empty ⇒ tile hidden
    let costLine: String?        // e.g. "$3.20 of $12" — optional
    let identity: String?        // account email — Settings ONLY, never notch
}

nonisolated enum UsageAuthPattern: Sendable {
    case localZeroConfig, piggybackNetwork, apiKey, cookieImport
}

nonisolated struct UsageFetchContext: Sendable {
    let now: Date
    let readFile: @Sendable (String) -> String?        // path under ~
    let http: UsageHTTPClient                          // bounded, redacting
    let credential: @Sendable (UsageProviderID) -> String?  // Rafu Keychain
    let cookieHeader: @Sendable (UsageProviderID) -> String? // nil until W1
}

protocol UsageFetchStrategy: Sendable {
    var id: String { get }
    func isAvailable(_ context: UsageFetchContext) async -> Bool
    func fetch(_ context: UsageFetchContext) async throws -> UsageSnapshot
    func shouldFallback(on error: Error) -> Bool
}

nonisolated struct UsageProviderDescriptor: Sendable {
    let id: UsageProviderID
    let displayName: String
    let authPattern: UsageAuthPattern
    let disclosure: String   // "reads X; sends only the token to Y…"
    let defaultEnabled: Bool // true ONLY for local zero-config
    let makeStrategies: @Sendable (UsageFetchContext) -> [any UsageFetchStrategy]
}
```

Pipeline: try strategies in order; skip `!isAvailable`; on throw continue
only if `shouldFallback`; first success wins; total failure ⇒ nil
snapshot ⇒ tile hidden. Pure, headless-tested with fake strategies.

`UsageHTTPClient`: injectable transport (`@Sendable (URLRequest) async
throws -> (Data, HTTPURLResponse)` with a URLSession default), 15s
timeout, honors 429 `Retry-After` (per-provider in-memory gate), and
REDACTS: no header, token, or body ever appears in thrown errors or any
log. Tests assert redaction.

`UsageSQLite`: `import SQLite3` (system module — NO Package.swift
change). Open read-only (`SQLITE_OPEN_READONLY`), string queries with
bound parameters only, returns rows as `[String: String]`. Adapt
CodexBar's reader shape (MIT, attribute in header).

`UsageStores`: enable + show-in-strip order (UserDefaults suite-name
pattern like `NotchCompanionPreferenceStore`); credential store =
Rafu's OWN Keychain generic passwords (`service "rafu.usage.<id>"`),
never UserDefaults (AGENTS).

## Stub files (all 19, compiling, honest)

Each `<Name>Provider.swift` stub contains the descriptor with correct
`displayName`/`authPattern`/`disclosure`/`defaultEnabled` and
`makeStrategies` returning `[]`, plus a doc comment naming its phase.
Claude and Codex stubs are NOT stubs: W0 migrates the existing shipped
local parsers (`ClaudeUsageParser` transcripts, `CodexUsageParser`
rollouts) into them as real `localZeroConfig` strategies — behavior on
main must be identical before/after W0 (same tiles, same numbers).
Basenames: `ClaudeProvider, CodexProvider, ClineProvider,
OpenCodeProvider, OpenCodeGoProvider, CursorProvider,
AntigravityProvider, GrokBuildProvider, GeminiCLIProvider,
KiloCodeProvider, CopilotProvider, WindsurfProvider, AmpProvider,
FactoryDroidProvider, OpenRouterProvider, KimiProvider, WarpProvider,
QwenProvider, QoderProvider`.

## Settings "Usage" tab

Registry-driven rows (see parent plan "Registration panel"): detection
state, disclosure line, enable toggle, show-in-strip control; Connect
button / key field / cookie-import affordances render per `authPattern`
but may be non-functional placeholders where the pattern's phase hasn't
landed (disabled with "arrives with provider support"). Stub providers
(empty strategies) show as "Not yet supported" rows or are hidden —
advisor decides; recommend hidden to keep the tab honest.

## Definition of done

- Contract lands byte-compatible with this file's names.
- Companion behavior unchanged for Claude/Codex local tiles (screenshot
  compare is the COORDINATOR's job post-merge; W0 agent stays headless).
- All gates green; new core/store tests; existing 1072+ suite untouched
  or migrated, never weakened.
- `AGENTS.md`, `Package.swift` untouched.
- Handoff lists: exact public symbol inventory (for W1–W8 reference),
  anything the stubs need that the contract lacks.
