# Usage widgets (WidgetKit)

## Status

**Active (2026-11-15).** The user approved the widget designs. Packaging and data
path decision: [ADR 0039](../../decisions/0039-widgetkit-extension-packaging.md).

| Step | State |
|---|---|
| W0 packaging (SwiftPM `RafuWidgets` appex assembled by `build_and_run.sh`, signing order, snapshot read) | Done, except the widget gallery check (see below) |
| W1 Rings widget (small, medium), shared usage code, theme inks, usage link | Delivered (2026-11-15, merge of commit c30a519); signed-build manual checks owed (see below) |
| W2 Hundred widget, daily usage log, snapshot v3 | Delivered (2026-11-15, commit bb1c43a, merge e23da21); no GUI check yet (see below) |
| W3 Seven widget ("Agent usage by day"), estimated-day flag | Delivered (2026-11-15, commit 1aadade, merge e962e3e); main passed both modes; no GUI or gallery check yet |
| W4 Board widget ("Agent usage board"), shared widget drawing | Delivered (2026-11-15, commit e24fa64, merge 34a2dea); branch passed parallel; main gate run by coordinator; no GUI or gallery check yet |

Widget catalog (kinds, families, states, accessibility, drawing rules):
[`usage-widgets-catalog.md`](../../references/usage-widgets-catalog.md).

## Work log

**2026-11-17, "N% today" fix (code commit 8e6297f, merged on main).** "N% today" now
means used percent since local midnight, not the current window slice. Snapshot
`Window` gains optional `todayStart` and `todayUsed` (no version bump); pure
`WidgetTodayText` in `RafuWidgetShared`. Dots, columns, and the pace line stay
window-slice based on purpose. Root cause, rule, and evidence:
[`usage-widgets-catalog.md`](../../references/usage-widgets-catalog.md) ("Today
text"). Both test modes passed on main after the merge. Not checked on the desktop yet.

**2026-11-15, W3 and W4 (merges e962e3e and 34a2dea).** Decision amendment:
[ADR 0039](../../decisions/0039-widgetkit-extension-packaging.md). Toolchain:
Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0, Mac17,13. Widget
behavior: [`usage-widgets-catalog.md`](../../references/usage-widgets-catalog.md).
Estimated rule: [`usage-sample-log.md`](../../references/usage-sample-log.md).

- **W3 Seven widget** (kind `dev.vatsalsaglani.rafu.widgets.seven`, `systemMedium`
  one provider, `systemLarge` two). Pure `WidgetSevenPresentation`.
- **W3 estimated flag.** `Window.dailyEstimated: Bool?` in snapshot v3, no version
  bump. `UsageDailyBreakdown.estimated`.
- **W3 test-data trap.** Moving `now` forward more than 6 h hits `abandonedAge`
  and the widget shows "Rafu not running". Reset-passed and day-boundary tests
  must use windows near their boundary.
- **W3 tests.** `WidgetSevenTests` (21), `UsageDailyEstimateTests` (7).
- **W4 Board widget** (kind `dev.vatsalsaglani.rafu.widgets.board`,
  `systemExtraLarge`; `systemExtraLargePortrait` only behind
  `if #available(macOS 27.0, *)`). Each row reuses the Hundred and Seven cards.
- **W4 shared drawing.** Moved verbatim to
  `Sources/RafuWidgets/WidgetDotDrawing.swift`; one `UsageNotConnectedView`. Future
  widgets reuse it.
- **W4 publisher rule.** `WidgetSnapshotPublisher.widgetKinds` must list every
  registered kind (4 now). `WidgetBoardTests.publisherReloadsEveryWidgetKind`
  asserts the exact list. No test can check the bundle's registrations, because
  the extension is an executable target.
- **W4 size.** Debug `RafuWidgets` binary is about 2.3 MB. It uses Canvas and SF
  Symbols only.
- **W4 tests.** `WidgetBoardTests` (11).
- **Evidence.** After W3, main passed both modes: 495 tests in 36 suites and 3839
  tests in 313 suites, in parallel and in `--no-parallel` (serial). W4 branch,
  parallel: 495 tests and 3850 tests in 314 suites. W4 main gate run by
  coordinator; no result is recorded here. No device or gallery check for any
  widget.

**Manual checks owed for all four widgets (no device check yet).** On a signed
Lightning build (`RAFU_SIGN_IDENTITY`):

- Gallery check: every widget appears and can be added.
- Each family in light, dark, accented, vibrant, and increased contrast.
- VoiceOver reads the one sentence for each widget.
- Text fit: the 9 pt weekday letters (Seven) and the `caption2` legend (Seven,
  Board).
- Real `systemExtraLarge` and `systemExtraLargePortrait` sizes on macOS 27 (Board).
- A tap opens the right surface.

**2026-11-15, W2 (commit bb1c43a, merge e23da21 "W2 Hundred widget, daily usage
log, snapshot v3").** Decision amendment:
[ADR 0039](../../decisions/0039-widgetkit-extension-packaging.md). Toolchain:
Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0, Mac17,13.
Behavior, rules and limits: [`usage-sample-log.md`](../../references/usage-sample-log.md).

- **Daily usage log.** `UsageSampleLog` (pure value) and `actor UsageSampleLogStore`
  keep bounded, identity-free records (35 days, 20,000 records, 2 MiB) in
  `Application Support/<App Name>/Usage/usage-samples.json`, outside the widget
  folder. Written only from a staged Rafu or Rafu Lightning bundle.
- **Daily split.** `UsageDailyBreakdown` gives 7 values (past days, today so far,
  `nil` for future) for windows with `windowMinutes == 10080`, in 24-hour slices
  from the window start.
- **Snapshot v3.** Reader accepts 1 to 3. `Window` gains optional `windowStart` and
  `daily`. The publisher attaches the split in a detached task; write tasks chain
  so the newest snapshot is written last; both widget kinds are reloaded.
- **Hundred widget** "Agent usage dots" (kind
  `dev.vatsalsaglani.rafu.widgets.hundred`, small and medium): 100 dots, pure
  `WidgetHundredPresentation`, `WidgetTimelinePlan` day-boundary entries, no
  animation.
- **Tests.** `UsageSampleLogTests` (18 tests), `WidgetHundredTests`. A mutating
  call inside `#expect` does not compile; assign first.
- **Evidence.** W2 branch parallel suite: 487 tests in 35 suites and 3816 tests in
  311 suites. Main gate run by coordinator. No GUI check.
- **Known limits.** The publisher fingerprint excludes the split (it shows on the
  next percent change or the 15-minute keep-alive reload). Gaps and a log that
  starts mid-window are interpolated and not marked as estimated in W2 (W3 added an
  estimated flag). The log grows only while Rafu runs (no Codex rollout backfill).
  The log is not deleted when a provider is turned off (35-day expiry).

**W2 manual checks owed (no device check yet).** On a signed Lightning build:
the Hundred widget in the gallery, small and medium; accented and vibrant modes;
light and dark; Color and Monochrome; the VoiceOver sentence; "today" moving at a
day boundary without a reload.

**2026-11-15, W1 (merge "W1 Rings widget with shared usage code, theme inks,
usage link", commit c30a519).** Decision amendment:
[ADR 0039](../../decisions/0039-widgetkit-extension-packaging.md). Toolchain:
Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0, Mac17,13.

- **Shared code.** Usage types moved to `RafuWidgetShared` (public, Foundation
  only, `-application-extension`). `RafuApp` re-exports it
  (`@_exported import RafuWidgetShared`), so no app call site changed. The app
  keeps a `nonisolated` `make(snapshot:...)` overload in
  `UsageRingClusterBuilder+Snapshot.swift`; app-only card rules are in
  `Usage/UsageCardPresentation.swift`. New `UsageLevelThresholds` (80/95) and
  monochrome opacity steps. The extension never links the GUI target.
- **Snapshot v2.** Optional `inks` from `RafuTheme.widgetInkSet` (cached per theme
  id; System theme writes both light and dark), `Provider.source`,
  `Provider.tokenSummary`. The reader accepts versions 1 and 2. Token-only
  providers appear only for `.localEstimate`. The extension never parses theme
  JSON.
- **Rings widget (small and medium).** Pure `WidgetRingsPresentation` runs the
  app's cluster and pace rules per entry date. It follows Color/Monochrome,
  Used/Remaining, and the theme inks. `widgetAccentable`; plain shapes, no
  animation. States: not connected, Rafu not running (snapshot older than 6 h),
  stale (older than 20 min or last refresh failed), reset passed, local
  estimate, running out, at limit. Live `Text(resetsAt, style: .relative)`. One
  VoiceOver sentence. Small shows 1 provider, medium shows 2.
- **Timeline.** `WidgetTimelinePlan` covers up to 6 h: now, hourly, each
  `resetsAt`, the 20-min stale point, each provider's observed time + 20 min, and
  the 6-h point. Policy `.atEnd`.
- **Reload rule.** Reload on change and when 15 min passed since the last reload
  (`keepAliveInterval`). Reload-on-change-only leaves an old `writtenAt`, so the
  widget showed stale after 20 min. About 4 reloads per hour while Rafu runs. Risk:
  the WidgetKit budget (about 40 to 70 per day) may throttle reloads, and the
  widget then shows an honest stale state.
- **Usage link.** `rafu://usage` (release) and `rafu-lightning://usage`
  (Lightning) from `RafuDeepLink`; `CFBundleURLTypes` in the staged `Info.plist`
  with a `plutil` check in `build_and_run.sh`. Target order
  (`UsageDeepLinkTarget`): menu bar card, then notch/island panel pinned on
  Usage, then Settings > Usage. Rules, the SwiftUI `openSettings` limit, and the
  security review: [`usage-deep-link.md`](../../references/usage-deep-link.md).
- **Isolation nuance.** An extension method in `RafuApp` on a type from another
  module needs `nonisolated` on each member (`UsageRingClusterBuilder+Snapshot.swift`);
  see [`nonisolated-extension-isolation-trap.md`](../../references/nonisolated-extension-isolation-trap.md).
- **Tests.** `Tests/RafuAppTests/Usage/WidgetRingsTests.swift` (27 tests);
  `RafuDeepLinkTests` covers the rejected forms (19 bad forms).
- **Evidence.** The implementor's parallel suite was green on the branch. Main gate
  run by coordinator (both modes); no result is recorded here.

**W1 manual checks owed (no device check yet).** On a signed Lightning build:

- Tap the widget with Rafu running, and with Rafu not running.
- No new `WindowGroup` window appears.
- The right surface opens (menu bar card, notch/island panel, or Settings > Usage).
- Rendering in small and medium, accented and vibrant modes, light and dark.
- VoiceOver reads the one sentence.

**2026-11-15, W0 and the SDK stamp (merge "real SDK stamp, optional signing
identity", commit 2968d3a).**

- Found and fixed: every SwiftPM-built Mach-O was stamped sdk 15.0, so the system
  treated Rafu as linked against the macOS 15 SDK, including for WidgetKit. Now
  minos 15.0 sdk 27.2 for `RafuLightning`, the `rafu` CLI, `rafu-agent-events`,
  the `RafuWidgets` appex and `MediaRemoteAdapter.framework` (vtool).
  [`sdk-build-version-stamp.md`](../../references/sdk-build-version-stamp.md).
- Added `RAFU_SIGN_IDENTITY` and `RAFU_SIGN_KEYCHAIN`, the stamp check and its
  self-test, and the widget gallery check steps:
  [`build-and-run.md`](../../references/build-and-run.md).
- Extension facts recorded in the ADR: `-e _NSExtensionMain` is required (SIGTRAP
  in `_EXRunningExtension._shared` without it); the data path is a read-only
  home-relative temporary exception (read OK on the snapshot, parent LIST denied,
  `~/.claude` and `~/.zshrc` denied); the App Group fails under ad-hoc signing
  (`containermanagerd`, error 513).
- Evidence: serial suite on `main` after the SDK merge passed, 466 tests in 33
  suites and 3729 tests in 302 suites. `SDKStampScriptTests` has 3 tests.

**Open (not verified):**

- The widget gallery check. Gallery visibility with ad-hoc signing is unconfirmed;
  `chronod` logs "purging instead because we shouldn't cache it ... isApple?
  false". A real Apple Development identity was not tested (none on the machine).
- Release needs Developer ID signing and notarization in `release.yml`.
- A move to a `<TEAMID>.dev.vatsalsaglani.rafu` App Group once Developer ID
  signing exists.
- No GUI check yet; the user tests everything at the end.
