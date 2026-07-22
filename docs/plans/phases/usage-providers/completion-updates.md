## Plan 2 (W2) - Mostly Blocked

The advisor found a hard scope/security conflict, so implementation is paused before source edits.

Claude/Codex local usage is currently default-on. Adding OAuth auto-discovery would silently send credentials without opt-in. The permitted files contain no separate consent state or Settings Connect action; disabling the whole provider would break existing local fallback behavior.

Exact W2 therefore needs authorization for these additional paths:

- `Sources/RafuApp/Usage/UsageRegistryReader.swift`
- `Sources/RafuApp/Usage/UsageStores.swift`
- `Sources/RafuApp/Settings/UsageSettingsTab.swift`
- Focused consent/store tests
- `docs/decisions/0017-usage-provider-trust-transition.md`
- `docs/decisions/README.md`

The provider files and named OAuth tests remain as originally scoped. The worktree is now on local branch `codex/usage-w2-exact-percent-oauth`; nothing was pushed or merged.

Please authorize those narrowly scoped exceptions so I can start the implementor pass.

Committed the verified, owned-path W2 backend slice as `3468252` on `codex/usage-w2-exact-percent-oauth`. Working tree is clean; nothing was pushed or merged.

Implemented:

- Consent-gated Claude and Codex OAuth strategies with local fallbacks.
- Exact endpoints, headers, credential parsing, expiry checks, response mapping, and redacted failures.
- 25 focused OAuth tests, including hostile-error redaction and zero-network-without-consent coverage.

Headless gates passed:

- `swift build`
- `swift test` — 1,121 tests
- `swift test --no-parallel` — 1,121 tests
- `./script/format.sh --lint`
- `git diff --check`

W2 is not fully production-connected: its specification also requires the credential/consent bridge and ADR 0017, but those live outside the explicitly permitted provider/test paths. Completing that portion requires authorization to edit the shared usage reader/store, Settings consent UI and tests, plus the ADR and decision index.

W2 is blocked by contradictory source-of-truth requirements:

- [W2](</Users/vatsalsaglani/.codex/worktrees/cfca/rafu/docs/plans/phases/usage-providers/W2-exact-percent-oauth.md>) requires a `UsageRegistryReader` credential bridge and ADR 0017.
- [README](</Users/vatsalsaglani/.codex/worktrees/cfca/rafu/docs/plans/phases/usage-providers/README.md>) forbids editing shared files, Settings, or documentation—only provider stubs and provider tests are owned.

The allowed implementation is committed as `3468252`; all headless gates pass and the branch is clean. Completing W2 exactly requires either authorizing those shared/documentation paths or assigning the bridge and ADR to a separate owning phase.

## Plan 4 (W4) - Mostly Blocked

W4 implementation is complete in its four owned paths, but I stopped before committing because the full gates expose a stale unowned test:

- Focused W4 tests: 14/14 pass.
- `swift build`: passes, zero warnings on the warm gate.
- Format/lint: clean.
- Both full test modes fail only at [UsageStoreTests.swift:99](/Users/vatsalsaglani/.codex/worktrees/9093/rafu/Tests/RafuAppTests/Usage/UsageStoreTests.swift:99). It expects only Claude/Codex rows, but W4 correctly adds Cline/OpenRouter/Qwen per the fixed-strategy-count contract.

May I update that unowned assertion to expect all five visible providers, then rerun both gates and commit?

W4 is implemented on `codex/usage-w4-api-key-providers`, touching only its four owned paths.

Verification:

- Formatting/lint: pass
- `swift build`: pass
- W4 focused tests: 15/15 pass
- Full parallel and serial tests: 1,109/1,110 pass

The sole failure is a stale shared W0 assertion in [UsageStoreTests.swift](/Users/vatsalsaglani/.codex/worktrees/9093/rafu/Tests/RafuAppTests/Usage/UsageStoreTests.swift:99). It expects only Claude/Codex, but W4 correctly adds Cline/OpenRouter/Qwen.

I have not edited that unowned file or committed a red branch. Please explicitly authorize adding `UsageStoreTests.swift` to W4 ownership for the one-line expectation update; I’ll then rerun both full gates and commit.

W4 is now formally blocked by the ownership contract.

The mandatory full gates fail only at [UsageStoreTests.swift:99](/Users/vatsalsaglani/.codex/worktrees/9093/rafu/Tests/RafuAppTests/Usage/UsageStoreTests.swift:99), an unowned shared W0 test. W4’s four owned files remain cleanly scoped, and its 15 focused tests pass.

To unblock completion and commit, authorize updating that assertion to include `.cline`, `.openRouter`, and `.qwen`.

## Plan 5 (W5) - Completed

Implemented W5 and committed it locally as `16da983` on `codex/usage-w5-local-token-providers`. Worktree is clean; nothing was pushed or merged.

- Gemini: reads `~/.gemini/oauth_creds.json` and settings; calls Cloud Code `loadCodeAssist`, optional project discovery, then `retrieveUserQuota`.
- Kimi: reads its CLI credential and optional device ID; calls `https://api.kimi.com/coding/v1/usages`.
- Copilot: stable unavailable stub. CodexBar has no discoverable local CLI/`gh` token; cookie-only budget enrichment was not implemented.
- Source basis: CodexBar commit `cc8da27cec92029a6435bfee4a703a719290234e`.
- Changed only the three [provider files](/Users/vatsalsaglani/.codex/worktrees/7db3/rafu/Sources/RafuApp/Usage/Providers/GeminiCLIProvider.swift) and [W5 tests](/Users/vatsalsaglani/.codex/worktrees/7db3/rafu/Tests/RafuAppTests/Usage/LocalTokenProvidersTests.swift).

Verification:

- `swift build`: passed.
- Format/lint and `git diff --check`: clean.
- Focused W5 tests: 16/16 passed.
- Both full test modes: 1,111/1,112 passed. The sole failure is the out-of-scope W0 assertion at `UsageStoreTests.swift:99`, which must add `.geminiCLI`, `.copilot`, and `.kimi` to its expected visible providers.
- A cold pre-change build emitted an existing `RafuTerminalView.swift:54` actor-isolation warning; W5 did not touch that file.

## Plan 3 (W3) - Mostly Blocked

Implemented and committed W3 on `codex/usage-w3-local-sqlite-providers`.

Commit: `a400cb4bd7bc5202daf73360d2e32ae9f8dca082`

Delivered:

- Cursor `state.vscdb` token strategy, JWT/cookie synthesis, usage API mapping, redacted failures.
- Local OpenCode and OpenCode Go SQLite strategies.
- CodexBar-derived message/part cost de-duplication and `$12/$30/$60` caps.
- Nine fixture-based tests covering schemas, filtering, auth absence, resets, response mapping, and redaction.
- Only the five W3-owned paths changed; worktree is clean.
- No push, merge, or GUI launch performed.

Verification:

- `swift build`: passed, zero warnings.
- W3 tests parallel and serial: 9/9 passed.
- Formatting lint and diff checks: passed.
- Full parallel and serial suites: 1105 tests, one shared-test failure in [UsageStoreTests.swift](/Users/vatsalsaglani/.codex/worktrees/1931/rafu/Tests/RafuAppTests/Usage/UsageStoreTests.swift:99). It hard-codes `[.claude, .codex]`, but W3 correctly exposes three additional non-stub providers. Updating that W0-owned path is prohibited by the phase contract, so the coordinator must update the assertion before repository-wide gates can be green.

CodexBar’s current OpenCode provider is web-cookie based; only OpenCode Go currently provides this SQLite schema. Following W3’s explicit scope, the local reader was adapted for non-Go OpenCode rows while excluding `providerID='opencode-go'` to prevent duplicate accounting.

Goal recorded as blocked after three consecutive confirmations.

The committed W3 implementation is clean at `a400cb4`. Completion requires a coordinator-owned update to [UsageStoreTests.swift:99](/Users/vatsalsaglani/.codex/worktrees/1931/rafu/Tests/RafuAppTests/Usage/UsageStoreTests.swift:99), whose expected visible-provider list predates W3. The ownership rules prohibit fixing it on this branch.

After that shared assertion is updated, resume this goal to rerun both complete test modes and finish verification.

## Plan 1 (W1) - Completed

Implemented and committed W1 on `codex/usage-w1-cookie-infrastructure`.

Delivered:

- Chromium Chrome/Brave/Edge/Arc cookie import with bound SQLite queries and v10/v11 decryption.
- Typed Safari Full Disk Access handling and bounded binarycookies parser.
- Firefox `moz_cookies` support.
- Main-actor, one-shot user-initiated imports with cancellation-safe, process-shared per-browser backoff.
- In-memory plus Rafu-owned Keychain cache with redaction and concurrency protection.
- 17 fixture-only tests; no real browser or Keychain access.
- MIT attribution from the studied CodexBar/SweetCookieKit implementation.

Primary API: [BrowserCookieImporter.swift](/Users/vatsalsaglani/.codex/worktrees/0e78/rafu/Sources/RafuApp/Usage/Cookies/BrowserCookieImporter.swift:304)  
Cache API: [CookieHeaderCache.swift](/Users/vatsalsaglani/.codex/worktrees/0e78/rafu/Sources/RafuApp/Usage/Cookies/CookieHeaderCache.swift:101)

Coordinator wiring remains the requested one-liner:

```swift
cookieHeader: { CookieHeaderCache.shared.header(for: $0) }
```

Verification:

- `swift build` — clean
- `swift test` — 1,113 passed
- `swift test --no-parallel` — 1,113 passed
- Focused W1 tests — 17 passed
- Format fix/lint and diff checks — clean
- Worktree clean; exactly six owned paths changed
- No GUI launch, push, or merge

Commit: `c400a8f` (`Implement W1 browser cookie infrastructure`)

No new reusable platform nuance required documentation outside the owned paths.

Goal usage: 626,461 tokens over about 1h 3m.
---

## Coordinator resolution (2026-07-22)

**Root cause of the W3/W4/W5 "blocked" status:** all three were blocked by
ONE shared W0-owned test — `UsageStoreTests.swift`'s
`settingsModelHidesStubProviders` hard-coded `visibleRows == [.claude,
.codex]`, which breaks the moment any phase makes its providers visible.
That is a coordinator-owned assertion, not phase work. Fixed on `main`
(commit `0404644`) to test the visibility MECHANISM with a synthetic
stub instead of a frozen list — no phase merge needs to touch it again.

**Merged to `main`:** W1 (`c9de367`) and W5 (`a90f523`). Suite green at
1130 tests, both modes, 0 warnings.

### W3 — ready to merge (no agent work left)
Committed at `a400cb4`, disjoint owned paths, blocker resolved. The
coordinator can merge `codex/usage-w3-local-sqlite-providers` directly.

### W4 — next steps (implementation done, just uncommitted)
Work sits UNCOMMITTED in the worktree (`ClineProvider`, `OpenRouterProvider`,
`QwenProvider` modified + `ApiKeyProvidersTests.swift` untracked); the branch
`codex/usage-w4-api-key-providers` is still at the base commit.
> /goal Finish W4. The shared-test blocker is RESOLVED on main — do NOT
> touch UsageStoreTests.swift. On branch codex/usage-w4-api-key-providers,
> commit your four owned paths (ClineProvider.swift, OpenRouterProvider.swift,
> QwenProvider.swift, Tests/RafuAppTests/Usage/ApiKeyProvidersTests.swift)
> with a descriptive message. Re-run the focused gates (swift build 0
> warnings; swift test --filter for your providers; format --lint). Report
> the commit hash. Do not push or merge; the coordinator merges onto main
> (which already carries the test fix, so the full suite is green there).

### W2 — next steps (needs authorized scope expansion)
The backend OAuth slice is committed (`3468252`), but exact-% requires the
credential/consent bridge in SHARED files plus ADR 0017 — legitimately
outside W2's provider/test ownership. This is AUTHORIZED: W2's phase doc
already assigns it the bridge + ADR. No other phase touches these files
(verified disjoint), so the expansion is conflict-free.
> /goal Complete W2. You are AUTHORIZED to additionally own and edit:
> Sources/RafuApp/Usage/UsageRegistryReader.swift,
> Sources/RafuApp/Usage/UsageStores.swift,
> Sources/RafuApp/Settings/UsageSettingsTab.swift,
> docs/decisions/0017-usage-provider-trust-transition.md,
> docs/decisions/README.md, and focused consent/bridge tests under
> Tests/RafuAppTests/Usage/. Implement the credential bridge EXACTLY per the
> W0 handoff recipe in W2-exact-percent-oauth.md: pre-resolve the needed
> credentials into a Sendable [UsageProviderID: String] inside the async
> UsageRegistryReader.snapshots(now:) before building the context; keep
> UsageFetchContext.credential SYNC; turning makeContext async is
> source-compatible. Add the Settings "Connect" action as the ONLY site the
> Claude Keychain read may occur (file read first, Keychain only on that
> explicit action), with per-provider consent state so exact-% is opt-in and
> the local fallback stays default-on. Write ADR 0017 (the trust transition:
> credentialed network calls, opt-in defaults, no token refresh, redaction)
> and index it. Do NOT touch other phases' provider files. Gate headlessly
> (build 0 warnings; swift test + --no-parallel green; format --lint) and
> commit on codex/usage-w2-exact-percent-oauth. Report; coordinator merges.

### Wave B (W6/W7/W8) — now unblocked
W0+W1 are on main, so the cookie-provider phases can branch from main and
run per their goal prompts in the README. W8 additionally waits on W4.
