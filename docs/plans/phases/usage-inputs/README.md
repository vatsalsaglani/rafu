# Usage inputs — parallel worktree execution plan

Completes the usage-providers feature end-to-end: the Settings tab already
has enable toggles + Connect/Disconnect (piggyback providers) from W2, but
the **API-key** and **cookie-import** providers have no way to be populated,
and the production cookie read is still a nil stub. Plus a CodexBar de-brand
+ one real Antigravity bug fix.

Three phases, engineered for **parallel** execution by independent agents in
separate git worktrees off `main`, then local merges by the coordinator —
same discipline as the usage-providers plan.

## Why these three fan out safely (disjoint owned paths)

The natural feature split (API-key field / cookie import) would put two
agents in `UsageSettingsTab.swift` at once — a conflict. So the split is by
**file ownership**, not feature:

```
U1  Settings inputs   → owns Sources/RafuApp/Settings/UsageSettingsTab.swift (+ its test)
U2  cookie read wire   → owns Sources/RafuApp/Usage/UsageRegistryReader.swift (+ its test)
U3  CodexBar de-brand  → owns the provider/cookie files + a NOTICE doc (+ their tests)
```

- **U1** adds BOTH the API-key `SecureField` and the "Import from browser"
  button to the tab. It only **calls** existing W0/W1 APIs
  (`UsageCredentialStore.shared.setCredential`, `CookieHeaderCache.shared.store`,
  `BrowserCookieImporter`) — it never edits those files.
- **U2** is the one-line production wiring `cookieHeader:
  { CookieHeaderCache.shared.header(for: $0) }` + a test. `header(for:)` is
  synchronous and self-hydrating (no async bridge like credentials needed).
- **U3** owns everything CodexBar-related: user-facing string fixes, the
  Antigravity creds-path bug, and attribution consolidation. Disjoint from U1
  (Settings) and U2 (reader).

No two phases touch the same file. They merge in any order; the cookie
providers only light up once **both** U1 (import) and U2 (read) land, but
that ordering is invisible to the merge.

## Worktree ground rules (every phase prompt includes these)

- Dedicated worktree branch. Commit ON THIS BRANCH in verified stages. Never
  push, merge, checkout `main`, or rebase.
- Gates per stage: `swift build` 0 warnings; `swift test` AND
  `swift test --no-parallel` green; `./script/format.sh --fix` then `--lint`
  clean. HEADLESS ONLY — do NOT run `build_and_run.sh`, launch/kill `Rafu.app`,
  or screencapture (the coordinator does GUI passes on `main` post-merge).
- Touch ONLY your owned paths. If a shared file seems to need changing, STOP
  and report in the handoff instead of editing it.
- Privacy invariants carry over from the parent plan: keys/cookies/tokens
  never logged, never persisted outside Rafu's own Keychain; no
  `@unchecked Sendable`; `nonisolated` members in PRIMARY type bodies (the
  SIGTRAP-off-main trap). Reuse the advisor→implementor flow.
- **Keep MIT attribution.** The `// Adapted from CodexBar … MIT` file headers
  are a legal condition of adapting that code — U1/U2 must not remove any;
  only U3 touches attribution, and only to CONSOLIDATE it, never delete it.

## Merge protocol (coordinator, on `main`)

When the user reports "phase Un is done on branch `<branch>`":
1. `git diff main...<branch> --stat` — verify only owned paths changed.
2. Gates on the branch tip.
3. `git merge --no-ff <branch>`; any conflict = owned-paths violation → back
   to the agent.
4. Re-run gates on `main`; GUI pass for U1 (Settings) and the cookie
   end-to-end once both U1+U2 are in.
5. Record in the status table.

## Status

| Phase | File | Branch | Status |
|---|---|---|---|
| U1 | [U1-settings-inputs.md](U1-settings-inputs.md) | — | ready |
| U2 | [U2-cookie-read-wiring.md](U2-cookie-read-wiring.md) | — | ready |
| U3 | [U3-codexbar-debrand.md](U3-codexbar-debrand.md) | — | ready |

## Per-phase goal-mode prompts

**U1:**
> /goal Implement phase U1 exactly as scoped in
> docs/plans/phases/usage-inputs/U1-settings-inputs.md. Read that file AND
> docs/plans/phases/usage-inputs/README.md first. Use the advisor→implementor
> workflow. Obey the worktree ground rules (headless gates only, commit on
> this branch, never push/merge, touch ONLY UsageSettingsTab.swift + your own
> test file — CALL the existing credential/cookie APIs, never edit them).

**U2:**
> /goal Implement phase U2 exactly as scoped in
> docs/plans/phases/usage-inputs/U2-cookie-read-wiring.md. Read that file AND
> docs/plans/phases/usage-inputs/README.md first. Use the advisor→implementor
> workflow. Obey the worktree ground rules (headless gates only, commit on
> this branch, never push/merge, touch ONLY UsageRegistryReader.swift + its
> test).

**U3:**
> /goal Implement phase U3 exactly as scoped in
> docs/plans/phases/usage-inputs/U3-codexbar-debrand.md. Read that file AND
> docs/plans/phases/usage-inputs/README.md first. Use the advisor→implementor
> workflow. Obey the worktree ground rules (headless gates only, commit on
> this branch, never push/merge, touch ONLY the provider/cookie files, their
> tests, and the new NOTICE doc). KEEP all MIT attribution — consolidate, do
> not delete.
