# U — Agent usage providers (Cursor, Cline, OpenCode, exact Claude %)

Status: planned (2026-07-22). Extends the shipped Notch Companion usage
strip (terminal-notch-hud.md NC-D) from two hardcoded local parsers to a
provider registry covering more agents and better data. No implementation
yet — this document is the brainstorm outcome and staged plan.

Depends on: Notch Companion (shipped), `AgentUsage.swift` (the current
`AgentUsageProvider`/`AgentUsageReader` seam), ADR 0016 amendment (reading
other tools' local files).

## Prior art: CodexBar (MIT — code-compatible)

[CodexBar](https://github.com/steipete/CodexBar) is steipete's MIT menu
bar app showing usage for 60+ providers. **MIT means we may adapt its
code directly** (unlike GPLv3 open-vibe-island) — with attribution in the
file header and a NOTICE entry when we do. Its architecture and per-
provider data sources were read from a full source clone on 2026-07-22;
the load-bearing facts below are quoted from that reading, not the README.

### The architecture worth mirroring (simplified)

One registry of per-provider descriptors; each descriptor resolves an
ORDERED list of fetch strategies (`oauth → cli → web`, etc.); the pipeline
tries them in order with an explicit `shouldFallback(on:)` gate; every
strategy returns the same `UsageSnapshot` (up to three rate windows, each
`usedPercent` + `windowMinutes` + `resetsAt`, plus optional cost/identity).
Rafu's version should be smaller: we only adopt the descriptor + ordered
strategies + shared snapshot shape, not the browser/WebView machinery.

### What each provider actually needs (verified from source)

| Provider | Zero-config path | Data | Network? | Rafu verdict |
|---|---|---|---|---|
| **Claude (exact %)** | read Claude Code's OAuth token: `~/.claude/.credentials.json`, else Keychain item `"Claude Code-credentials"` → `GET https://api.anthropic.com/api/oauth/usage` (`anthropic-beta: oauth-2025-04-20`) | REAL `five_hour`/`seven_day` (+ per-model 7d) utilization % + `resets_at` + monthly extra-usage credits | Yes (Anthropic API, bearer token) | **U-B — the headline upgrade.** Replaces our token-total estimate with the same % Claude Code shows. Keychain read triggers a macOS consent prompt: read the FILE first, Keychain only on explicit user action |
| **Codex** | (shipped) rollout tail parse; CodexBar instead reads `~/.codex/auth.json` → `https://chatgpt.com/backend-api/wham/usage` | our parse: 5h/7d % (stale until next session); OAuth: fresh % + credits | OAuth path yes | Keep local-first; optional OAuth freshness later (U-E) |
| **Cursor** | read Cursor.app's own token from SQLite `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` (`ItemTable` key `cursorAuth/accessToken`) → synthesize `WorkosCursorSessionToken` cookie → `GET https://cursor.com/api/usage-summary` (+ `/api/auth/me`) | plan % used, on-demand $ used/limit, billing-cycle reset, plan name | Yes (cursor.com) | **U-C.** Zero-config (no browser cookies needed — skip that whole path) |
| **OpenCode / OpenCode Go** | local SQLite `~/.local/share/opencode/opencode.db` (sum `$.cost` from `message`/`part` rows) + `~/.local/share/opencode/auth.json` presence check | $ spend vs caps (session/weekly/monthly) → % | **No** (fully local) | **U-C.** Cheapest add — same class as our Codex parser, just SQLite instead of JSONL. Web/Zen enrichment: skip |
| **Cline** | none — needs an API key (env `CLINE_API_KEY` or user-entered) → `GET https://api.cline.bot/api/v1/users/me/plan/usage-limits` | `five_hour`/`weekly`/`monthly` `percentUsed` + `resetsAt` | Yes | **U-D.** Only provider needing a Settings credential field (stored in OUR Keychain, per AGENTS) |

### What we deliberately do NOT adopt from CodexBar

- **Browser cookie import** (Safari needs Full Disk Access; huge privacy
  surface, gate/circuit-breaker complexity). Rejected for Rafu outright.
- **WKWebView dashboard scraping** and **PTY-driving agent CLIs** for
  usage. Fragile, heavyweight, and against Rafu's calm-native posture.
- **In-app login flows.** Rafu piggybacks on sessions the user's agents
  already own, or takes a pasted API key; it never runs its own OAuth
  browser dance for third-party tools.

## The trust transition (ADR required before U-B)

NC-D's contract was: local files, read-only, no network, no credentials.
U-B/U-C/U-D cross two explicit lines:

1. **Network calls carrying a user credential** (Anthropic, cursor.com,
   cline.bot). Only the token/key ever leaves the machine, only to that
   provider's own first-party endpoint, only to READ usage numbers.
   Nothing else is transmitted — no content, no telemetry, no other
   fields. Responses are parsed for the metric fields only.
2. **Reading other apps' credential stores** (Claude's credentials file,
   Cursor's state.vscdb). File reads are silent; the Claude KEYCHAIN item
   read raises a macOS consent dialog — it must only ever happen from an
   explicit user action in Settings (CodexBar needed a whole gate system
   because it reads in the background; we avoid the problem by policy).

Rules, to be codified in a new ADR:

- Per-provider **opt-in**: network-using providers ship OFF; the shipped
  local-only parsers (codex rollouts, claude transcripts, opencode db)
  stay on by default. Each Settings row states plainly what is read and
  where the request goes.
- Tokens/keys: never logged, never persisted by Rafu except user-entered
  keys in Rafu's OWN Keychain entries; other apps' tokens are held in
  memory for the request only, never copied to disk or Keychain.
- All fetches off-main, bounded timeouts (15s), honor 429 `Retry-After`,
  TTL-gated (existing 60s/180s cadence); a failing provider hides its
  tile — never a fake number, never a blocked panel (NC-D rules carry
  over verbatim).
- Token refresh: v1 does NOT refresh other tools' expired tokens (CodexBar
  refreshes Claude/Codex tokens with the CLIs' public client IDs; that is
  a deeper impersonation step — deferred, revisit only with its own ADR).
  An expired token = tile falls back to the local estimate.

## UI implications (companion peek panel)

- The usage strip stays ONE line by default; with >2 enabled providers it
  wraps to a compact grid in the peek panel (still muted, tabular).
- % tiles get a subtle emphasis when a window is near exhaustion (e.g.
  ≥80%: the number goes accent; never color alone — the % text IS the
  signal). No alerts, no notifications — glanceable only, for now.

## Registration panel (decided 2026-07-22: Settings ONLY, own tab)

Provider registration lives exclusively in a new Settings **"Usage"**
tab — never in the notch panel. Rationale: registration is durable
configuration (credentials, consent, enable state); the notch is
glanceable-only, and the trust-transition ADR requires consent-bearing
actions (the Claude Keychain read, key entry) to happen from an explicit
user action in a predictable place. Settings also gives the mandatory
menu/keyboard path (`⌘,`) for free.

One row per provider, same anatomy, three fill patterns:

1. **Local zero-config** (codex rollouts, claude token estimate, opencode
   db): no registration — a detection state ("Active · reading
   `~/.codex/sessions`") and an enable toggle. Default ON.
2. **Piggyback network** (Claude exact %, Cursor): detection state
   ("Claude Code login found") + an explicit **Connect** button. The
   Connect press is the ONLY site where the Claude Keychain read (and its
   macOS consent dialog) may occur — never during background refresh.
   Default OFF until connected.
3. **Key-entry** (Cline): masked API-key field stored in Rafu's OWN
   Keychain + a "Test" action performing one fetch and reporting the
   outcome inline. Default OFF.

Every row carries: the plain-language disclosure line ("reads X; sends
only the token to Y to fetch usage numbers"), the connection status
(Connected as `account@…` / expired / not found — identity shown in
Settings only, never in the notch), and the enable toggle.

The notch surface stays read-only about all of this: enabled+working
providers render tiles; a failing/expired provider silently hides its
tile (no error badges in the notch); zero enabled providers = no strip
and NO "set up usage" call-to-action in the panel.

## Stages

| Stage | Contents | Size |
|---|---|---|
| U-A | Registry refactor: `UsageProviderDescriptor` + ordered strategies + shared `UsageSnapshot` (3 windows + optional cost); migrate the two shipped parsers onto it unchanged; per-provider enable store; Settings "Usage" TAB with the provider-row anatomy above (detection states + toggles for the local providers; Connect/key rows land with their providers in U-B/U-D) | M |
| U-B | Claude exact %: credentials-FILE read → `api/oauth/usage` fetch strategy ahead of the transcript fallback; opt-in toggle; Keychain path only via explicit "Connect" button in Settings; ADR lands WITH this stage | M |
| U-C | OpenCode local SQLite provider (no network — can ship default-on) + Cursor provider (state.vscdb token → usage-summary; opt-in) | M |
| U-D | Cline: API-key field (Rafu Keychain) + usage-limits fetch; opt-in | S |
| U-E (optional) | Codex OAuth freshness (auth.json → wham/usage) behind the same opt-in pattern; near-exhaustion emphasis polish | S/M |

Gates per stage: the standard six (build 0 warnings, both test modes,
format lint, staged-app launch, screenshot pass for UI stages) plus, for
every network strategy: a fixture-driven parser test, a no-credential →
tile-hidden test, and a redaction audit (no token in any error/log path).

## Open questions (decide before U-B)

1. SQLite reads (Cursor state.vscdb, opencode.db): Foundation has no
   SQLite API — link `libsqlite3` directly (CodexBar ships a `CSQLite3`
   shim target; MIT, small, adaptable) or hand-roll a minimal reader?
   Recommendation: tiny `CSQLite3`-style system-library shim, read-only
   flags, no third-party package.
2. Does `api/oauth/usage` count against any user quota or raise abuse
   flags at unusual UAs? CodexBar spoofs `claude-code/<version>` as UA.
   Recommendation: send an honest `Rafu/<version>` UA first; only revisit
   if the endpoint rejects it.
3. Provider identity display: show account email (available from most
   endpoints) in Settings to disambiguate multi-account setups? Cheap,
   useful — recommend yes, Settings-only (never in the notch).
