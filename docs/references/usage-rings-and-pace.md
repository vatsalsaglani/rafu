# Usage rings, pace estimates, and exact Claude usage

- Applies to: the notch Usage section (`CompanionUsageSectionView`), the
  Settings ▸ Usage provider cards (`UsageProviderCardView`), the pure rules in
  `Sources/RafuApp/Usage/UsagePace.swift`, the Claude OAuth parser
  (`ClaudeOAuthStrategy.parseUsage`), and the refresh-time Claude Code
  Keychain re-read (`UsageCredentialStore.refreshClaudeKeychainCredential`).
- Last verified: Apple Swift 6.4, macOS 27.0.1 (26A434), 2026-10-19.
  Native build, full parallel and serial tests, and Lightning launch.
  Settings loaded live Claude and Codex usage with exact-source labels.

## Rule or observed behavior

### Why Claude showed "123K tok" and no ring

Every reason, in the order a refresh meets it:

1. **Not connected.** Exact usage needs Settings ▸ Usage ▸ Connect. Without
   it, `ClaudeOAuthStrategy` is unavailable and the local transcript
   estimate wins. That estimate has token totals and never a percentage, so
   no ring can draw. Before this change, nothing outside Settings said so.
2. **The Connect credential lived only in memory.** On macOS, Claude Code
   keeps its OAuth record in the Keychain item `Claude Code-credentials`;
   `~/.claude/.credentials.json` is usually absent. Connect read the item
   once and kept the token in process memory. After a relaunch, or when the
   token expired (Claude Code replaces it on its own schedule), consent was
   still recorded, Settings still said "Connected", but no usable credential
   existed, so every refresh silently fell back to the estimate.
3. **401/403** also falls back to the estimate (by design; an expired token).
4. **429, transport, malformed, and server errors** hid the whole card
   (by design: never fabricate a local result for an exact failure).
5. **Parsing gaps.** Only the first model-scoped weekly lane from `limits`
   was kept; the top-level `seven_day_opus` / `seven_day_sonnet` keys were
   ignored; a `utilization` above 100 dropped the whole window; no window
   carried its length, so no pace could be estimated.

### What changed

- `UsageWindow.windowMinutes` (additive, default `nil`) and
  `UsageSnapshot.source` (`UsageDataSource`, additive, default
  `.unspecified`). Existing memberwise calls compile unchanged.
- Claude: Session `5h` (300 min), Weekly `7d` (10 080 min), then one lane
  per model: `seven_day_opus`, `seven_day_sonnet`, then each
  `weekly_scoped` entry in `limits`, de-duplicated by model id AND display
  name, "all models" excluded, capped at six windows in total. The model
  lanes decode leniently; `five_hour`, `seven_day`, and `limits` stay strict.
- `utilization` is a 0–100 percentage. A value from 0 to 1 is a small
  percentage, never a fraction to multiply (that guess would show 1 % as
  100 %). A value over 100 (up to 1 000) clamps to 100; a negative or absurd
  value drops that window.
- `UsageDateParsing` keeps the first three fraction digits when a server
  sends microseconds (`…00.123456+00:00`), because not every
  `ISO8601DateFormatter` build accepts more.
- After Connect, a refresh may re-read `Claude Code-credentials` when consent
  exists and neither the file nor the memory copy is usable. It is
  rate-limited to once per 15 minutes per process, a denial stops all
  re-reads until the next Connect or Disconnect, and only an unexpired
  credential is cached (in memory, as before). This is the bounded exception recorded in
  [ADR 0027](../decisions/0027-connected-usage-refresh.md).
- A failed refresh keeps the last good snapshot for up to 6 hours, marked
  stale ("Showing the last successful update"), only while the provider is
  enabled and — for exact data — network consent still exists.

### Pace (`UsagePace.estimate`)

Ported from Cider. Inputs: the used percentage, the window length, the
reset time, and when the snapshot was observed. `elapsed = observedAt −
(reset − length)`; `rate = used / elapsed`; `projected = rate × length`.

| State | Rule | Note |
|---|---|---|
| exhausted | used ≥ 100 (checked first, needs no reset) | "Limit reached · wait for reset" |
| runningOut | projected > 100 | "May run out in 1h 20m" |
| tight | 95 ≤ projected ≤ 100 | "Tight · near the limit at reset" |
| enough | otherwise | "On pace · ~N% spare at reset" |
| unknown | no percent / observation older than 20 min / no reset / reset passed / no or bad length / elapsed under 15 min | one note per reason |

An elapsed reset takes priority over exhausted: a retained 100% window
must ask for new data after its reset, not tell the user to keep waiting.
The exhausted state still works without a known reset.

### Presentation rules

- Ring level follows the USED share and the pace, never the display mode:
  warning at 80 % used or a warning pace, critical at 95 % or exhausted.
  Above normal, the ring uses the warning/error token AND a triangle glyph,
  and VoiceOver hears "warning".
- `UsageDisplayMode` (Used/Remaining) persists in `UsageDisplayModeStore`
  (`usageDisplayMode` key, suite-name idiom) and lives on
  `NotchCompanionModel` so the notch and Settings agree.
- The ring draws no sweep under Reduce Motion. Cards update their countdowns
  through `TimelineView(.periodic(from: .now, by: 60))`, which runs only
  while the card is on screen.
- The notch's "Connect for exact usage…" opens Settings ▸ Usage through
  `SettingsPaneRouter` + `openSettings()` (after `NSApp.activate()`, since
  the notch panel never activates the app). The Settings card's button runs
  the existing `UsageSettingsModel.connect` flow and then refreshes.

## Why it matters

Exact percentages were available all along but invisible unless the person
found Connect, and they vanished again on the next launch. Rings without a
window length cannot estimate pace, and a ring that only changes colour
fails the colour-alone rule.

## Reproduction or evidence

`Tests/RafuAppTests/Usage/UsagePaceTests.swift` (synthetic data only) and the
updated `ClaudeOAuthTests.claudeOAuthMapsUsageFixture` (the fixture now
yields four windows). On Linux these ran in a scratch package with a
Security-framework stub: 56 tests passed, together with the existing Claude
and Codex OAuth tests. That is not evidence for the repo suite.

## Verification commands

```bash
./script/format.sh --lint
./script/build.sh
swift test --filter UsagePace
swift test --filter ClaudeOAuth
./script/build_and_run.sh --verify   # then open the notch Usage tab and Settings ▸ Usage
```

Manual checks: a not-connected Claude card shows the token line, "Estimated
from local transcripts", and the Connect button; after Connect it shows 5h,
7d, and model rings with "↻" countdowns; relaunch Rafu and confirm the rings
return without a second Connect (one Keychain prompt at most); toggle
Used/Remaining; enable Reduce Motion; check VoiceOver on a ring.

## Related code, ADRs, and phases

- Code: `Usage/UsagePace.swift`, `Usage/Providers/ClaudeProvider.swift`,
  `Usage/UsageStores.swift`, `Usage/UsageRegistryReader.swift`,
  `Views/UsageRingView.swift`, `Views/UsageProviderCardView.swift`,
  `Views/NotchSectionViews.swift`, `Settings/UsageSettingsTab.swift`,
  `Settings/SettingsPaneNavigation.swift`.
- ADR: [`../decisions/0017-usage-provider-trust-transition.md`](../decisions/0017-usage-provider-trust-transition.md)
  and [ADR 0027](../decisions/0027-connected-usage-refresh.md).
- References: [`usage-provider-contract.md`](usage-provider-contract.md),
  [`notch-companion.md`](notch-companion.md).

## Mac integration review, 2026-10-19

Reviewed with Apple Swift 6.4 on macOS 27.0.1 (26A434). Two regression
cases were added: results arriving after Disable or Disconnect must not
restore forbidden snapshots, and a retained full window must stop reporting
exhausted after its reset. The synthetic tests cover both without reading
Keychain or making provider requests.

The macOS accessibility tree exposed the custom Used/Remaining control as
two buttons with the same inherited accessibility label. The display-mode
control now contains separate accessible buttons, and the shared themed
segmented control exposes the selected trait. Its theme colors stay intact. Check both option names and selection in the accessibility
tree; visual labels alone do not prove keyboard or VoiceOver usability.
