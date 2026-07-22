# W8 — Alibaba pair: Qoder + Qwen cookie path (dual-region)

WAVE B: requires W0 AND W1 merged. ALSO reads (never modifies) the
`QwenProvider.swift` W4 delivered — if W4 hasn't merged when this
worktree is cut, STOP and report; this phase APPENDS Qwen's cookie
strategy to that file and must not race it.

## Owned paths

- `Sources/RafuApp/Usage/Providers/QoderProvider.swift`
- `Sources/RafuApp/Usage/Providers/QwenProvider.swift` (APPEND the
  cookie strategy to W4's structure; reuse its region enum — do not
  restructure)
- `Tests/RafuAppTests/Usage/AlibabaProvidersTests.swift`

## Scope

From `Sources/CodexBarCore/Providers/{Qoder,Alibaba}` (adapt, attribute):

**Qoder** (`cookieImport`, cookie-ONLY): endpoints
`https://qoder.com/api/v2/me/usages/big_model_credits` and the
`.com.cn` mirror; cookie domains per its importer. Region selection
shares the pattern W4 established for Qwen (per-provider stored region
preference). Map big-model-credit usage to windows/costLine per the
source's snapshot model.

**Qwen cookie path**: append a cookie strategy AFTER the W4 key
strategy (key ranks first), using the Alibaba cookie importer's
domains/session names from source, honoring the same region preference.

Both: default OFF, cached-header consumption only (no import
triggering), disclosures naming region-specific hosts explicitly (a
user should see whether `.com` or `.com.cn` will be contacted).

## Tests

Fixture responses (both regions) → snapshot; region preference switches
host; absent cookie ⇒ unavailable; key-beats-cookie ordering for Qwen
(with both present, key strategy result wins); invalid-credentials
typed + gated; redaction. Injected transport only.

## Definition of done

Gates green; owned paths only (QwenProvider diff is purely additive —
show it in the handoff); observed endpoint/cookie facts recorded for
the coordinator's reference note.
