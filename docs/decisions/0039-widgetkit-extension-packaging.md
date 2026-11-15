# ADR 0039: WidgetKit extension packaging and data path

- **Status:** Accepted (2026-11-15). The user approved the widget designs.
  Gallery visibility with ad-hoc signing is **not confirmed** (see Consequences).
- **Date:** 2026-11-15
- **Related:** [ADR 0037](0037-dynamic-island-macs.md) (it deferred Live
  Activities and WidgetKit until macOS 27.3)

## Context

Rafu is a SwiftPM package. `script/build_and_run.sh` assembles the `.app` by hand.
WidgetKit needs a sandboxed app extension (`.appex`) inside `Contents/PlugIns`.
The widgets show agent usage. They need data from the app, and the extension is
sandboxed.

## Options considered

Packaging:

1. **SwiftPM executable plus a script-assembled appex.** Chosen.
2. An `xcodebuild`-only extension project. Not chosen.
3. Move the app to Xcode. Not chosen.

Data path from the app to the extension:

1. **A home-relative read-only temporary exception.** Chosen for now.
2. An App Group container. Rejected for ad-hoc signing (below); planned with
   Developer ID.
3. Timeline only (no shared data). Not chosen.

## Decision

**Target and link.** A SwiftPM executable `RafuWidgets`, linked with
`-Xlinker -application_extension -Xlinker -e -Xlinker _NSExtensionMain`. Without
`-e _NSExtensionMain` the extension crashes at start with SIGTRAP in
`_EXRunningExtension._shared`. Shared pure code lives in `RafuWidgetShared`, built
with `-application-extension`.

**Bundle.** The appex `Info.plist` has `CFBundlePackageType` `XPC!` and
`NSExtensionPointIdentifier` `com.apple.widgetkit-extension`. The bundle id is the
app bundle id plus `.widgets`. There is one bundle id and one data folder per
variant (release and Lightning).

**Signing.** Sign the appex first, then the app. See
[`build-and-run.md`](../references/build-and-run.md) for the script contract.

**Data.** The extension sandbox has the entitlement
`com.apple.security.temporary-exception.files.home-relative-path.read-only` for
`/Library/Application Support/<App>/Widgets/`. Verified: reading the snapshot
works; listing the parent is denied; `~/.claude` and `~/.zshrc` are denied. The
app writes the snapshot atomically; the extension only reads. The snapshot holds
no credentials and no identity. The extension must never read `~/.claude` or
`~/.codex`.

**App Group rejected for now.** With ad-hoc signing, `containermanagerd` refuses
the group (group ids must be prefixed by the requestor's Team ID) and the write
fails with error 513. Move to a `<TEAMID>.dev.vatsalsaglani.rafu` App Group when
Developer ID signing is in place.

**Distribution.** Temporary exceptions are not allowed on the Mac App Store but
are allowed for Developer ID. Release needs Developer ID signing and
notarization added to `release.yml`.

**Families and rendering.** macOS 27 families: `systemSmall`, `systemMedium`,
`systemLarge`, `systemExtraLarge`, and the new `systemExtraLargePortrait` (macOS
27 only). No accessory families on macOS. Rendering modes: `fullColor`,
`accented`, `vibrant`.

## Amendment 2026-11-15: W1 shared code, snapshot v2, reload rule, usage link

Merge "W1 Rings widget with shared usage code, theme inks, usage link" (commit
c30a519).

**Shared code.** The usage types the widget needs moved from the GUI target to
`RafuWidgetShared`: `UsageWindow`, `UsagePace`, `UsageDisplayMode`,
`UsageRingPalette`, `UsageRingLevel`, `UsageWindowPresentation`, the ring cluster
types, and the builder `make(windows:...)`. They are `public`, use Foundation
only, and are built with `-application-extension`. `UsageLevelThresholds` (80 and
95) and the monochrome opacity steps are new there. `RafuApp` re-exports the
module with `@_exported import RafuWidgetShared`, so no app call site changed. The
app keeps `make(snapshot:...)` as a `nonisolated` overload. App-only card rules
moved to `Usage/UsageCardPresentation.swift`. **The extension never links the GUI
target.**

**Snapshot v2.** New optional `inks` (light and dark accent, info, success,
warning, and critical as hex, from `RafuTheme.widgetInkSet`, cached per theme id;
the System theme writes both sets), `Provider.source`, and `Provider.tokenSummary`.
The reader accepts versions 1 and 2. A token-only provider appears only when its
source is `.localEstimate`. The extension never parses theme JSON; a user theme
file is read once per theme id, in the app.

**Reload rule.** The app reloads the timeline on a data change and also when 15
minutes passed since the last reload (`keepAliveInterval`). Reload on change only
leaves an old `writtenAt`, so the widget showed "stale" after 20 minutes. This is
about 4 reloads per hour while Rafu runs. Risk: the WidgetKit reload budget
(about 40 to 70 per day, not verified here) may throttle reloads; the widget then
shows an honest stale state.

**Usage link.** The widget opens Rafu with one URL scheme per variant, from
`RafuDeepLink`: `rafu://usage` (release) and `rafu-lightning://usage`
(Lightning). One scheme per variant means a Lightning widget never opens the
release app. The rules and the security review are in
[`usage-deep-link.md`](../references/usage-deep-link.md).

Platform and isolation nuances are in that note and in
[`usage-widgets.md`](../plans/phases/usage-widgets.md). The decision did not change
the packaging, signing, or data path above. The gallery question stays open.

## Phased plan

W0 to W4 and the daily usage log are tracked in
[`usage-widgets.md`](../plans/phases/usage-widgets.md).

## Consequences

- **Gallery visibility with ad-hoc signing is unconfirmed.** `chronod` logs
  "purging instead because we shouldn't cache it ... isApple? false". A real
  Apple Development or Developer ID identity may be needed. A real Apple
  Development identity was not tested (none on the machine).
- The temporary exception is a Developer-ID-only path; moving to the App Store
  would need the App Group.
- The widget build stamps the SDK like every other binary; see
  [`sdk-build-version-stamp.md`](../references/sdk-build-version-stamp.md).
- Diagnostics: call `/usr/bin/log` by full path (in zsh `log` is a shell
  builtin). The handoff also named `screencapture -l` as a widget diagnostic
  note, but gave no detail.

## Revisit trigger

Revisit when Developer ID signing exists (switch to the App Group and drop the
temporary exception), if the gallery refuses ad-hoc appexes, or if a future
macOS adds a widget path that does not need an extension.

## Related

- Reference: [`sdk-build-version-stamp.md`](../references/sdk-build-version-stamp.md),
  [`build-and-run.md`](../references/build-and-run.md),
  [`usage-deep-link.md`](../references/usage-deep-link.md)
- Phase: [`usage-widgets.md`](../plans/phases/usage-widgets.md)
