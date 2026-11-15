# Usage sample log and daily split

- Applies to: the usage sample log (`UsageSampleRecord`, `UsageSampleLog`,
  `UsageSampleLogStore`), the daily split (`UsageDailyBreakdown`), snapshot v3,
  and the Hundred widget's data. Widget presentation and packaging are in
  [`usage-widgets.md`](../plans/phases/usage-widgets.md) and
  [ADR 0039](../decisions/0039-widgetkit-extension-packaging.md).
- Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
  Mac17,13, 2026-11-15 (W2, commit bb1c43a, merge e23da21; estimated rule from W3,
  merge e962e3e). No GUI check yet.

## Rule or observed behavior

### Record and log rules

`UsageSampleRecord` holds: provider id, window label, used percent, `resetsAt`,
`observedAt`. JSON keys are short. It has no identity and no tokens.

`UsageSampleLog` is a pure value. It appends a record when:

- it is the first record for that window, or
- 15 minutes or more passed since the last record for that window, or
- `resetsAt` moved by more than 10 minutes (a smaller move is jitter).

It ignores a sample that is older than the newest one for that window, a sample
more than 60 s ahead of now, and a non-finite percent. A finite percent is
clamped to 0 to 100. If the clock is set back, later records are dropped.

Retention: 35 days, at most 20,000 records and 2 MiB, oldest first. A damaged
file, a newer format, or an oversize file reads as empty.

Stale providers are not logged.

### Store and file

`actor UsageSampleLogStore` reads the file once with a size limit, keeps the log
in memory, and writes atomically only when the log changes.

File: `~/Library/Application Support/<App Name>/Usage/usage-samples.json`. It is
not in the widget folder, so the extension cannot read it (the extension never
reads the log). `formatVersion` is 1; dates are seconds since 1970. It is written
only from a staged Rafu or Rafu Lightning bundle. `swift test` and `swift run`
never write it.

### Daily split (`UsageDailyBreakdown`)

- Slices are 24 hours from the window start (`resetsAt` minus 7 days). They are
  not calendar days, so a time-zone or DST change does not move a slice.
- A reset starts day 1. Only records with the current `resetsAt` between the
  window start and the current observation count.
- Level 0 at the window start; the last point is the current percent. A later
  lower value caps earlier values. No day is negative. The days sum to the
  current percent.
- Straight-line interpolation at the day boundaries spreads gaps.
- Output: 7 values (past days, today so far, `nil` for future days).
- Only windows with `windowMinutes == 10080` get a split.

### Estimated flag (W3)

`UsageDailyBreakdown.estimated` is true only when all three hold for two
neighbouring points: they are more than 2 h apart (`estimateGap`), a day boundary
lies between them, and the level goes up. An overnight gap with no use stays exact.
The broader rule in the brief (any gap across a day boundary) would have marked
almost every widget, so it was not used. A log that starts late is covered: the
first span runs from the window start at level 0, so it is a gap that goes up.

Snapshot: `Window.dailyEstimated: Bool?`. No version bump (the snapshot stays v3).
A missing key reads as `nil`, and `isDailyEstimated` maps `nil` to `false`. An older
extension ignores the key. The widgets show "est." and add "daily values estimated"
to the VoiceOver sentence ([`usage-widgets-catalog.md`](usage-widgets-catalog.md)).

Test-data trap: moving `now` forward more than 6 h hits `abandonedAge`, and the
widget shows "Rafu not running". Reset-passed and day-boundary tests must use
windows near their boundary. Tests: `UsageDailyEstimateTests` (7).

### Snapshot v3

`currentVersion` is 3 and `supportedVersions` is 1 to 3. `Window` gains optional
`windowStart` and `daily: [Double?]`, set on the first 7-day window of each
provider. The demo snapshot has a split.

The publisher builds log records from fresh providers only. It appends through the
actor and attaches the split in a detached task, writes the snapshot, then reloads
both widget kinds. Write tasks chain: each waits for the previous one and is not
cancelled, so the newest snapshot is written last.

## Hundred widget ("Agent usage dots")

Kind `dev.vatsalsaglani.rafu.widgets.hundred`, small and medium. Pure
`WidgetHundredPresentation`.

- 100 dots, in order: earlier days (two alternating bands), today, projected use
  by reset (all remaining dots when the pace is `runningOut`), then spare. A
  time-elapsed marker.
- Text: "41% used" or "59% left", "6% today", "Day 6 of 7". Remaining mode
  reverses.
- States as in W1: stale is dimmed and shows no projection; reset passed shows an
  empty grid and the headline "—".
- Shapes: Claude circles, Codex rounded squares. The second card switches shape on
  a collision.
- VoiceOver example: "Claude, weekly limit 41 percent used, day 6 of 7, 6 percent
  today, on pace, about 49 percent spare at reset, resets Friday".
- Two `Canvas` layers: the usage layer is `widgetAccentable`; the spare dots and
  the marker are not.
- `WidgetInk` inks, Color or Monochrome, increased contrast. No animation:
  WidgetKit has no continuous animation, so today's dots are brighter instead of
  pulsing.
- `WidgetTimelinePlan` adds day-boundary entries, so "today" moves without a
  reload.

## Known limits

- The publisher fingerprint excludes the split. A split change shows on the next
  percent change or the 15-minute keep-alive reload.
- Gaps and a log that starts mid-window are interpolated. W2 did not mark them;
  W3 marks them with the estimated flag (rule above).
- The log grows only while Rafu runs. The Codex rollout backfill is not done.
- The log is not deleted when a provider is turned off. Records expire after 35
  days.

## Why it matters

The Hundred widget shows earlier days and "today". The app builds them from a
small, bounded log with no identity and no tokens. The log is outside the widget
folder, and the extension never reads it; it receives only the split inside the
snapshot.

## Reproduction or evidence

Tests: `UsageSampleLogTests` (18 tests) and `WidgetHundredTests`. The W2 branch
parallel suite was green: 487 tests in 35 suites and 3816 tests in 311 suites.
Main gate run by coordinator.

Testing nuance: a mutating call inside `#expect` does not compile. Assign the
result to a `let` first. See [`concurrency.md`](concurrency.md).

## Verification

```bash
swift test --filter UsageSampleLogTests
swift test --filter WidgetHundredTests
swift test --filter UsageDailyEstimateTests
```

## Related code, ADRs, and phases

- `UsageSampleRecord`, `UsageSampleLog`, `UsageSampleLogStore`,
  `UsageDailyBreakdown`, `WidgetHundredPresentation`, `WidgetTimelinePlan`
  (`rg -n "UsageSampleLog|UsageDailyBreakdown|WidgetHundredPresentation" Sources`)
- [ADR 0039](../decisions/0039-widgetkit-extension-packaging.md) (amendments W2, W3)
- [`usage-widgets-catalog.md`](usage-widgets-catalog.md)
- [`usage-rings-and-pace.md`](usage-rings-and-pace.md)
- Phase: [`usage-widgets.md`](../plans/phases/usage-widgets.md)
