# Usage providers — parallel worktree execution plan

Parent plan: [`../agent-usage-providers.md`](../agent-usage-providers.md)
(roster of 19, auth rules, trust transition, prior art). This folder
splits that plan into NINE phases (W0–W8) engineered for parallel
execution by independent agents in separate git worktrees, then local
merges back into `main` by the coordinator.

## Dependency graph

```
W0 (shared shim)  ── MUST merge to main FIRST, serial, blocks everything
 ├─ Wave A (parallel, branch from main after W0 merges):
 │    W1  cookie infrastructure (no providers)
 │    W2  exact % via own tokens: Claude OAuth + Codex OAuth + trust ADR
 │    W3  SQLite/local: Cursor, OpenCode, OpenCode Go/Zen
 │    W4  API-key: Cline/ClinePass, OpenRouter, Qwen (key path)
 │    W5  local-token: Gemini CLI, GitHub Copilot, Kimi/Moonshot
 └─ Wave B (parallel, branch from main after W0 AND W1 merge):
      W6  Antigravity, Grok Build, Kilo Code
      W7  Windsurf, Amp, Factory Droid, Warp
      W8  Qoder + Qwen cookie path + Alibaba dual-region plumbing
```

Within a wave, phases merge in ANY order — their owned paths are
disjoint by construction. Wave B phases need W1's cookie module on
`main` before branching.

## The zero-conflict rule (why this fans out safely)

W0 creates EVERYTHING shared: the provider core (IDs, snapshot,
descriptor, strategy protocol, pipeline), the registry listing all 19
descriptors, one compiling STUB file per provider, the support helpers
(HTTP client, SQLite reader, credential/enable stores), the Settings
"Usage" tab (registry-driven), and the companion grid migration. After
W0, a provider phase ONLY:

- rewrites the stub files it owns under
  `Sources/RafuApp/Usage/Providers/`;
- adds its own test/fixture files under `Tests/RafuAppTests/Usage/`.

A phase must NEVER touch: `Package.swift`, `UsageProviderRegistry.swift`,
`UsageProviderCore.swift`, the Settings files, the companion
model/views, another phase's provider or test files, `AGENTS.md`, or
`docs/` outside its own phase file's status line. If an agent believes a
shared file needs changing, it STOPS and reports the need in its handoff
instead of editing it.

## Worktree agent ground rules (every phase prompt includes these)

- You are on a dedicated worktree branch. Commit your work ON THIS
  BRANCH in verified stages. Never push, never merge, never checkout
  `main`, never rebase.
- Gates per stage: `swift build` 0 warnings; `swift test` AND
  `swift test --no-parallel` green; `./script/format.sh --fix` then
  `--lint` clean. HEADLESS ONLY — do NOT run `build_and_run.sh`, do not
  launch or kill `Rafu.app`, do not screencapture (the user's live app
  instance and notch strip must not be disturbed; integrated GUI passes
  happen on `main` after merge).
- Clone prior art yourself: `git clone --depth 1
  https://github.com/steipete/CodexBar` into your scratchpad and read
  `Sources/CodexBarCore/Providers/<X>/`. CodexBar is MIT: adapting code
  is allowed WITH attribution (file-header comment naming CodexBar +
  MIT). GPL sources remain forbidden.
- Privacy invariants (non-negotiable, from the parent plan): parse
  metric fields only, never message/prompt content; tokens/keys/cookies
  never logged and never persisted outside Rafu's own Keychain; every
  network fetch bounded (15s), off-main, TTL-respecting, 429-honoring;
  failure hides the tile — never a fake number, never a blocked panel.
  No `@unchecked Sendable`. `nonisolated` members live in PRIMARY type
  bodies, never bare extensions (runtime SIGTRAP off-main otherwise —
  see `docs/references/nonisolated-extension-isolation-trap.md`).
- Follow the advisor→implementor flow inside the phase if the phase is
  non-trivial (all of these are): advisor brief first, then implement.

## Merge protocol (coordinator, on `main`)

When the user reports "phase Wn is done on branch `<branch>`":

1. `git diff main...<branch> --stat` — verify only owned paths changed.
2. Run all gates on the branch tip.
3. `git merge --no-ff <branch>` into `main`; resolve nothing silently —
   any conflict outside trivial test-count noise means an owned-paths
   violation and goes back to the phase agent.
4. Re-run gates on `main`; for phases with UI surface (W0, W1) run the
   staged-app GUI pass now.
5. Record the merge in this README's status table.

## Status

| Phase | File | Branch | Status |
|---|---|---|---|
| W0 | [W0-shim.md](W0-shim.md) | merged | ✅ Merged |
| W1 | [W1-cookie-infrastructure.md](W1-cookie-infrastructure.md) | `codex/usage-w1-cookie-infrastructure` | ✅ Merged (1130 tests) |
| W2 | [W2-exact-percent-oauth.md](W2-exact-percent-oauth.md) | `codex/usage-w2-exact-percent-oauth` | ✅ Merged (1191 tests, ADR 0017) |
| W3 | [W3-local-sqlite-providers.md](W3-local-sqlite-providers.md) | `codex/usage-w3-local-sqlite-providers` | ✅ Merged (1139 tests) |
| W4 | [W4-api-key-providers.md](W4-api-key-providers.md) | `codex/usage-w4-api-key-providers` (`3c8ebff`) | ✅ Merged (1154 tests) |
| W5 | [W5-local-token-providers.md](W5-local-token-providers.md) | `codex/usage-w5-local-token-providers` | ✅ Merged (1130 tests) |
| W6 | [W6-cookie-providers-1.md](W6-cookie-providers-1.md) | `codex/usage-w6-*` | ✅ Merged (1206 tests) |
| W7 | [W7-cookie-providers-2.md](W7-cookie-providers-2.md) | `codex/usage-w7-*` | ✅ Merged (1224 tests) |
| W8 | [W8-alibaba-providers.md](W8-alibaba-providers.md) | `codex/usage-w8-*` | ✅ Merged (1238 tests) — plan complete |

## Per-phase goal-mode prompts

Copy-paste the matching prompt into the agent running in that phase's
worktree. Replace nothing; each prompt is self-contained.

**W0:**
> /goal Implement phase W0 exactly as scoped in
> docs/plans/phases/usage-providers/W0-shim.md. Read that file AND
> docs/plans/phases/usage-providers/README.md AND
> docs/plans/phases/agent-usage-providers.md first, in that order. Use
> the advisor→implementor workflow. Obey the worktree ground rules in
> the README (headless gates only, commit on this branch in verified
> stages, never push or merge). W0 is the shared shim every later phase
> builds on: the contract names and file layout in the phase file are
> binding.

**W1:**
> /goal Implement phase W1 exactly as scoped in
> docs/plans/phases/usage-providers/W1-cookie-infrastructure.md. Read
> that file AND docs/plans/phases/usage-providers/README.md first. Use
> the advisor→implementor workflow. Obey the worktree ground rules
> (headless gates only, commit on this branch, never push/merge, touch
> ONLY your owned paths). Clone CodexBar (MIT) per the README and study
> its cookie import stack before designing.

**W2:**
> /goal Implement phase W2 exactly as scoped in
> docs/plans/phases/usage-providers/W2-exact-percent-oauth.md. Read that
> file AND docs/plans/phases/usage-providers/README.md first. Use the
> advisor→implementor workflow. Obey the worktree ground rules (headless
> gates only, commit on this branch, never push/merge, touch ONLY your
> owned paths — your providers' stub files and your own tests).

**W3:**
> /goal Implement phase W3 exactly as scoped in
> docs/plans/phases/usage-providers/W3-local-sqlite-providers.md. Read
> that file AND docs/plans/phases/usage-providers/README.md first. Use
> the advisor→implementor workflow. Obey the worktree ground rules
> (headless gates only, commit on this branch, never push/merge, touch
> ONLY your owned paths).

**W4:**
> /goal Implement phase W4 exactly as scoped in
> docs/plans/phases/usage-providers/W4-api-key-providers.md. Read that
> file AND docs/plans/phases/usage-providers/README.md first. Use the
> advisor→implementor workflow. Obey the worktree ground rules (headless
> gates only, commit on this branch, never push/merge, touch ONLY your
> owned paths).

**W5:**
> /goal Implement phase W5 exactly as scoped in
> docs/plans/phases/usage-providers/W5-local-token-providers.md. Read
> that file AND docs/plans/phases/usage-providers/README.md first. Use
> the advisor→implementor workflow. Obey the worktree ground rules
> (headless gates only, commit on this branch, never push/merge, touch
> ONLY your owned paths). If a provider turns out cookie-only in
> CodexBar's source, stub that strategy as unavailable and record it in
> your handoff instead of implementing cookies.

**W6:**
> /goal Implement phase W6 exactly as scoped in
> docs/plans/phases/usage-providers/W6-cookie-providers-1.md. Read that
> file AND docs/plans/phases/usage-providers/README.md first. Verify the
> cookie module from W1 exists on your branch before starting (it merged
> to main before this worktree was created). Use the advisor→implementor
> workflow. Obey the worktree ground rules (headless gates only, commit
> on this branch, never push/merge, touch ONLY your owned paths).

**W7:**
> /goal Implement phase W7 exactly as scoped in
> docs/plans/phases/usage-providers/W7-cookie-providers-2.md. Read that
> file AND docs/plans/phases/usage-providers/README.md first. Verify the
> cookie module from W1 exists on your branch before starting. Use the
> advisor→implementor workflow. Obey the worktree ground rules (headless
> gates only, commit on this branch, never push/merge, touch ONLY your
> owned paths).

**W8:**
> /goal Implement phase W8 exactly as scoped in
> docs/plans/phases/usage-providers/W8-alibaba-providers.md. Read that
> file AND docs/plans/phases/usage-providers/README.md first. Verify the
> cookie module from W1 exists on your branch before starting. Use the
> advisor→implementor workflow. Obey the worktree ground rules (headless
> gates only, commit on this branch, never push/merge, touch ONLY your
> owned paths).
