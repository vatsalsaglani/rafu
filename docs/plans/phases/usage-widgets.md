# Usage widgets (WidgetKit)

## Status

**Active (2026-11-15).** The user approved the widget designs. Packaging and data
path decision: [ADR 0039](../../decisions/0039-widgetkit-extension-packaging.md).

| Step | State |
|---|---|
| W0 packaging (SwiftPM `RafuWidgets` appex assembled by `build_and_run.sh`, signing order, snapshot read) | Done, except the widget gallery check (see below) |
| W1 Rings widget (small, medium), shared usage code, theme inks, usage link | Delivered (2026-11-15, merge of commit c30a519); signed-build manual checks owed (see below) |
| W2 Hundred widget, daily usage log, snapshot v3 | Delivered (2026-11-15, commit bb1c43a, merge e23da21); no GUI check yet (see below) |
| W3 | Pending (adds an estimated flag for interpolated days) |
| W4 | Pending |

The scope of W3 and W4 was not given in the handoff; the lines above record state
only.

## Work log

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
  starts mid-window are interpolated and not marked as estimated in W2 (W3 adds an
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
