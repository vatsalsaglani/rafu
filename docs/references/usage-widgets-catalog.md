# Usage widgets catalog

- Applies to: the four WidgetKit usage widgets in `Sources/RafuWidgets/` (Rings,
  Agent usage dots, Agent usage by day, Agent usage board), their presentation
  types, and the shared drawing code. Packaging, signing and data path are in
  [ADR 0039](../decisions/0039-widgetkit-extension-packaging.md). Data rules are in
  [`usage-sample-log.md`](usage-sample-log.md).
- Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
  Mac17,13, 2026-11-15 (W3 merge e962e3e, W4 merge 34a2dea). Unit tests only. **No
  device or gallery check for any widget.**

## Catalog

| Widget (gallery name) | Kind | Families | Presentation |
|---|---|---|---|
| Rings (W1) | `dev.vatsalsaglani.rafu.widgets.rings` | `systemSmall` (1 provider), `systemMedium` (2) | `WidgetRingsPresentation` |
| Agent usage dots, "Hundred" (W2) | `dev.vatsalsaglani.rafu.widgets.hundred` | `systemSmall`, `systemMedium` | `WidgetHundredPresentation` |
| Agent usage by day, "Seven" (W3) | `dev.vatsalsaglani.rafu.widgets.seven` | `systemMedium` (1 provider), `systemLarge` (2) | `WidgetSevenPresentation` |
| Agent usage board (W4) | `dev.vatsalsaglani.rafu.widgets.board` | `systemExtraLarge`; `systemExtraLargePortrait` on macOS 27 only | `WidgetBoardPresentation` and `WidgetBoardRow`; rows come from `make(maxRows:)` |

The Hundred widget's dots, states and timeline are described in
[`usage-sample-log.md`](usage-sample-log.md). The Rings rules are in
[`usage-widgets.md`](../plans/phases/usage-widgets.md) (W1 log).

## Rules shared by all widgets

- States (W1): not connected, Rafu not running (snapshot older than 6 h,
  `abandonedAge`), stale (older than 20 min or last refresh failed; dimmed), reset
  passed, local estimate, running out, at limit.
- Used and Remaining modes, Color and Monochrome, theme inks, increased contrast.
- No animation. WidgetKit has no continuous animation, so emphasis is brightness.
- Shapes: Claude circles, Codex rounded squares. On a collision the shape switches.
- Two `Canvas` layers; only the filled usage dots are `widgetAccentable`.
- Tap: `widgetURL` to the usage link ([`usage-deep-link.md`](usage-deep-link.md)).
  The board has no per-row `Link`.
- The extension binary uses Canvas and SF Symbols only. Debug `RafuWidgets` is about
  2.3 MB.

## Seven ("Agent usage by day", W3)

Pure `WidgetSevenPresentation`. It has no clock of its own; the caller passes the
date.

**Columns.** 7 columns, one per 24-hour slice from the window start. The weekday
letter and full name come from `veryShortStandaloneWeekdaySymbols` at each slice
midpoint, using the caller's calendar and locale. Letters can repeat (T for Tuesday
and Thursday), so the full name is used for VoiceOver.

**Dots.** One dot per 1%. Day values are rounded from the running total, so the
columns add up to the headline. `.past` is filled. `.today` has the brightest fill
plus hollow dots up to the pace line. `.future` has hollow dots to the pace line
only. A column holds 16 dots (8 rows by 2). The rest is `overflow`, drawn as "+N".

**Pace line.**

- Used mode: 100/7, about 14.3% a day. Caption "Even pace · 14% a day".
- Remaining mode: (percent left + today's use) divided by days left including
  today. Caption "Each day left · ~16%".
- `paceLineRow` is capped at the top row.

**Text.** Header headline (used or left %), "Day N of 7", "6% today" (calendar day;
see "Today text" below),
`Text(resetsAt, style: .relative)`, status long text.

**States.** As in W1 and W2. Without a day split: hollow pace dots only and the
caption "Daily split after Rafu logs a day". Estimated days show "est." (rule in
[`usage-sample-log.md`](usage-sample-log.md)). Reset passed: no columns, a dim
placeholder chart icon, and "—".

**Layout.** Medium shows one provider. Large shows two, with an "Agent usage"
header, two panels, and the legend "1 dot = 1% of a weekly limit · dashed line =
pace".

**VoiceOver.** Example: "Claude, weekly limit 41 percent used, day 6 of 7,
Saturday 7 percent, ..., Wednesday 6 percent, today 6 percent so far, on pace,
about 49 percent spare at reset, resets Friday". When estimated it adds "daily
values estimated". In Remaining mode it adds "about N percent for each day left".

**Drawing.** Increased contrast gives stronger strokes. Tests: `WidgetSevenTests`
(21), `UsageDailyEstimateTests` (7).

## Today text: "N% today" is a calendar day (2026-11-17)

**Symptom.** Both widgets showed "0% today" (Claude 6% used, Codex 58% used).

**Root cause.** "Today" was the current 24-hour slice counted from the window start
(`resetsAt` minus 7 days), not the local calendar day. Real data on the user's Mac:

- Claude: reset 2026-11-23T13:00Z, so slices start at 13:00Z (18:30 IST). All samples
  (1% at about 03:00Z, 6% at 12:54Z) were before 13:00Z. The slices were `[6, 0, nil...]`.
  The 6% was used on the user's local day, but the slice count was 0.
- Codex: slice 6 started at 14:26:48Z and held 0.448, which rounds to 0.

**Rule.** "N% today" is the used percent since LOCAL midnight.

- `UsageDailyBreakdown.make(..., todayStart: Date? = nil)` sets
  `todayUsed = max(0, current - level(at: max(todayStart, windowStart)))`. It uses the
  same interpolation as the day slices. No `Calendar` in `RafuCore`; the caller passes
  the boundary. Default `nil` gives no value.
- Snapshot `Window` has optional `todayStart` and `todayUsed`. The snapshot version is
  not bumped: the Codable is synthesized, the keys are optional, and `supportedVersions`
  is a range. A test decodes an old v3 file without the keys.
- `WidgetSnapshotPublisher.attachDaily(_:log:calendar: = .current)` passes
  `startOfDay(for: provider.observedAt)`.
- Pure `WidgetTodayText` (`RafuWidgetShared`) makes the text for the Hundred and Seven
  presentations (Board follows Hundred). The caller passes `now` and a calendar.

| Case | Text |
|---|---|
| `now` is the same local day as `todayStart` | the value |
| `now` is a later day | 0 |
| value above 0 that rounds to 0 | "<1% today" (spoken "less than 1 percent today") |
| reset passed | no text (nil) |
| fields absent (older app) | the old slice count (`sliceCount` parameter) |

The Seven spoken today-column text follows the calendar value too.

**Intended mismatch.** The dots' today band, the seven-day columns, and the
Remaining-mode pace line stay window-slice based. So the text can differ from the
highlighted column: the column is a window slice, the text is a calendar day. Do not
"fix" this. Next-day "0% today" can show only within the stale window just after midnight.

**Tests.** 5 new in `UsageSampleLogTests`. New `WidgetTodayTextTests` (Asia/Kolkata and
UTC calendars, decode of an old file, round trip, publisher).

**Evidence.** Code commit 8e6297f, merged on main. Both modes passed on main after the
merge. Implementor, parallel: 3949 tests in 322 suites and 535 tests in 40 suites. Not
checked on the desktop yet: owed, check that the real widgets show the calendar value.

## Board ("Agent usage board", W4)

**Families and availability.** `systemExtraLarge`. `systemExtraLargePortrait` is
declared `@available(macOS 27.0, iOS 27.0)` in the macOS 27.2 SDK, and the
deployment target is macOS 15. Both `supportedFamilies` and every `family ==`
comparison need `if #available(macOS 27.0, *)`.

**The macOS 26 SDK does not compile it.** In the macOS 26 SDK (Swift 6.3.3, the
`macos-26` CI and release runners) the symbol is marked unavailable on macOS, so
`#available` alone fails the build: "'systemExtraLargePortrait' is unavailable in
macOS" (release run 43719940272, 2026-11-15). Wrap each use in
`#if compiler(>=6.4)` as well; Swift 6.4 ships with the macOS 27 SDK. A build
made on CI therefore has no portrait Board size until the runners move to the
macOS 27 SDK. A local build (Swift 6.4.2, macOS 27.2 SDK) has it. This Mac has
no Swift 6.3 toolchain, so only CI can check the macOS 26 SDK path: any new
macOS 27 API needs the same compile-time gate before a push.

**Rows.** One row per provider. Each row uses the same `WidgetHundredCard` and
`WidgetSevenCard` that the Hundred and Seven widgets make (a test checks equality).

- Landscape: a fixed 168 pt text column (name, headline, "Day N of 7 · N% today",
  pace sentence in the level colour, reset countdown), the Hundred grid, then the
  Seven chart. The chart keeps the "est." and "Daily split after Rafu logs a day"
  captions and the pace caption.
- Portrait: two-line text, Hundred above Seven.
- Header "Agent usage" with "Updated <time>" (the snapshot written time). Footer
  legend (may shrink to 75%; removed first if it does not fit) and "+N more".

**Row cap and order.** Cap 3 in both families (`make(maxRows:)`); 4 rows made the
grids too small in about 330 pt. If all rows fit, the order is the snapshot order,
so rows do not move between entries. If the cap applies, keep the 3 most urgent and
show them in snapshot order. Urgency rank: at limit 4, may run out 3, tight 2,
fresh or stale percent 1, reset passed or local estimate 0; then higher used
percent; then snapshot order.

**Shapes.** Claude circles, Codex rounded squares, others circles. A row whose shape
equals the row above flips (Claude, Gemini, Codex gives Codex circles). The grid and
chart in one row share a shape. Rows have names, so state is not colour-only.

**States.** As before. A stale snapshot dims every row.

**VoiceOver.** One element: "Agent usage, updated <time>", then each row's Hundred
sentence (plus ", daily values estimated"), then "N more agents not shown". The
Seven day list is left out, for length.

**Tap.** `widgetURL` to the usage link only.

**Tests.** `WidgetBoardTests` (11).

## Shared drawing

Moved verbatim to `Sources/RafuWidgets/WidgetDotDrawing.swift`: `HundredGrid`,
`HundredLayout`, `HundredLocalEstimateView`, `SevenHeadline`, `SevenResetCountdown`,
`SevenChartArea`, `SevenChart`, `SevenLayout`, and `WidgetDotShape.path(in:)`. One
`UsageNotConnectedView(reason:systemImage:)` serves all widgets. Future widgets
reuse these types; do not copy them.

## Publisher rule

`WidgetSnapshotPublisher.widgetKinds` must list every registered kind (4 now), or a
new widget never reloads. `WidgetBoardTests.publisherReloadsEveryWidgetKind` asserts
the exact list. No test can check the bundle's registrations, because the extension
is an executable target; adding a widget means updating the list by hand.

## Why it matters

Layout, caps and availability checks are decisions that unit tests cannot see on
a device. This note records them so a device pass checks the right things.

## Reproduction or evidence

After W3, main passed both modes: 495 tests in 36 suites and 3839 tests in 313
suites, in parallel and in `--no-parallel`. W4 branch, parallel: 495 tests and 3850
tests in 314 suites. W4 main gate run by coordinator; no result is recorded here.

## Owed checks (no device check yet)

On a signed Lightning build (`RAFU_SIGN_IDENTITY`):

- Gallery check for each widget.
- Each family in light, dark, accented, vibrant, and increased contrast.
- VoiceOver.
- Text fit: the 9 pt weekday letters and the `caption2` legend.
- Real `systemExtraLarge` and `systemExtraLargePortrait` sizes on macOS 27.
- A tap opens the right surface.

## Verification

```bash
swift test --filter WidgetSevenTests
swift test --filter WidgetBoardTests
swift test --filter WidgetHundredTests
swift test --filter WidgetRingsTests
```

## Related code, ADRs, and phases

- `Sources/RafuWidgets/` (`rg -n "WidgetSevenPresentation|WidgetHundredCard|widgetKinds" Sources`)
- [ADR 0039](../decisions/0039-widgetkit-extension-packaging.md)
- [`usage-sample-log.md`](usage-sample-log.md), [`usage-deep-link.md`](usage-deep-link.md),
  [`usage-rings-and-pace.md`](usage-rings-and-pace.md)
- Phase: [`usage-widgets.md`](../plans/phases/usage-widgets.md)
- Today text: `rg -n "WidgetTodayText|todayStart|todayUsed" Sources`
