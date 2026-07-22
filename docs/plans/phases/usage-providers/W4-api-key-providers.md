# W4 — API-key providers: Cline/ClinePass, OpenRouter, Qwen (key path)

Providers registered with a pasted API key stored in Rafu's own
Keychain (shim `UsageStores` credential store). All opt-in, default OFF.

**Contract rule:** `makeStrategies` must return the same strategy COUNT
regardless of `context` (Settings' visibility probe calls it with a
no-op/empty context) — all credential/availability gating belongs in
`isAvailable`, never in the strategy list's length.

## Owned paths

- `Sources/RafuApp/Usage/Providers/ClineProvider.swift`
- `Sources/RafuApp/Usage/Providers/OpenRouterProvider.swift`
- `Sources/RafuApp/Usage/Providers/QwenProvider.swift` (key path ONLY —
  the cookie path and dual-region cookie plumbing belong to W8; design
  the strategy list so W8 can APPEND a cookie strategy to this file
  without restructuring: keep region handling in a small
  `nonisolated` helper W8 can reuse)
- `Tests/RafuAppTests/Usage/ApiKeyProvidersTests.swift`

## Scope (verify each against CodexBar source; adapt with attribution)

**Cline/ClinePass** (`apiKey`): key from Rafu credential store, env
`CLINE_API_KEY`/`CLINEPASS_API_KEY` honored as availability hints.
`GET https://api.cline.bot/api/v1/users/me/plan/usage-limits`, Bearer.
Map `data.limits[]` (`five_hour`/`weekly`/`monthly`, `percentUsed`,
`resetsAt`) → windows (300/10080/43200 min). Cover pay-as-you-go: if
the response carries credit/PAYG fields (check CodexBar's snapshot
model), map to `costLine`.

**OpenRouter** (`apiKey`): CodexBar's provider shows credits by key —
verify its endpoint (`/api/v1/credits` or similar in source) and map
balance/usage to a costLine + percent-if-limited. Disclosure line must
note this tile also represents Roo Code / BYO-key spend routed through
OpenRouter.

**Qwen** (`apiKey` path): CodexBar's `Alibaba` coding-plan/token-plan
fetchers, key `ALIBABA_QWEN_API_KEY`, intl + `.com.cn` region selection
(a stored per-provider region preference — put the enum in
`QwenProvider.swift`, W8 reuses it). Map plan windows per source.

## Tests

Fixture responses per provider → snapshot mapping; no key ⇒ strategy
unavailable ⇒ nil snapshot; 401/403 ⇒ typed unauthorized (tile hidden,
no retry storm); 429 Retry-After honored via the shim gate (assert the
gate is consulted); redaction (key never in errors). Injected transport
only.

## Definition of done

Gates green; owned paths only; all three default OFF with correct
disclosure strings; Qwen file structured for W8's append; handoff notes
observed endpoint shapes.
