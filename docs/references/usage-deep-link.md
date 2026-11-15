# Usage deep link (widget tap)

- Applies to: the URL a usage widget opens (`rafu://usage`,
  `rafu-lightning://usage`), `RafuDeepLink`, `UsageDeepLinkTarget`, the
  `kAEGetURL` handler, `application(_:open:)`, and `CFBundleURLTypes` in the
  staged `Info.plist` (`script/build_and_run.sh`).
- Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
  Mac17,13, 2026-11-15. Build and unit tests only. No device check yet: a tap on a
  signed widget was not tested.

## Rule or observed behavior

**One scheme per variant.** Release uses `rafu://usage`. Lightning uses
`rafu-lightning://usage`. Both come from `RafuDeepLink`. A Lightning widget
therefore never opens the release app (the user's editor).

**Registration.** `CFBundleURLTypes` is in the staged `Info.plist`.
`build_and_run.sh` checks it with `plutil`.

**Exact match only.** Rafu accepts a URL only when all of these hold:

- the scheme is the variant's scheme and the host is `usage`;
- the path is `/` or empty;
- there is no query, fragment, user, password, or port;
- the URL is at most 64 bytes.

Any other URL is ignored. It is never logged and it starts no process.
`RafuDeepLinkTests` covers 19 bad forms.

**Receiving the URL.**

- The `kAEGetURL` Apple Event handler is installed in `willFinishLaunching` and
  again in `didFinishLaunching`, because SwiftUI may install its own handler.
- `application(_:open:)` is a fallback. It takes Rafu-scheme URLs out of the
  folder-open path, so a widget URL is never treated as a folder to open.
- A link that arrives during launch waits until the companion activates.

**Target order (`UsageDeepLinkTarget`).** Menu bar card, then the notch/island
panel pinned on Usage, then Settings > Usage.

**Platform nuance: opening Settings from AppKit.** SwiftUI `openSettings` exists
only inside a view. From AppKit, perform the app menu's command-comma "Settings..."
item after setting `SettingsPaneRouter`. This is fragile: it breaks if the menu
changes. Re-check it when the app menu changes.

**Isolation nuance.** An extension method in `RafuApp` on a type from another
module needs `nonisolated` on each member
(`UsageRingClusterBuilder+Snapshot.swift`). See
[`nonisolated-extension-isolation-trap.md`](nonisolated-extension-isolation-trap.md).

## Why it matters

A URL scheme is an input any process can send. The strict match keeps the link a
single "show Usage" request. It carries no path, no data, and no way to reach the
folder-open path or a process. One scheme per variant keeps Lightning
development from opening the user's release editor.

## Reproduction or evidence

Security review (2026-11-15): the rules above; the rejected forms are covered by
`RafuDeepLinkTests` (19 bad forms). The device behavior is not verified.

Owed on a signed Lightning build:

- Tap the widget with Rafu running, and with Rafu not running.
- No new `WindowGroup` window appears.
- The right surface opens.

## Verification

```bash
swift test --filter RafuDeepLinkTests
./script/build_and_run.sh --verify
```

`build_and_run.sh` runs the `plutil` check of `CFBundleURLTypes`. The main gate
(both test modes) is run by the coordinator; no result is recorded here.

## Related code, ADRs, and phases

- `RafuDeepLink`, `UsageDeepLinkTarget`, `SettingsPaneRouter`
- `Sources/RafuApp/Usage/UsageRingClusterBuilder+Snapshot.swift`, `Sources/RafuApp/App/UsageDeepLink.swift`, `Sources/RafuWidgetShared/RafuDeepLink.swift`, `Sources/RafuApp/Settings/SettingsPaneNavigation.swift` (`SettingsPaneRouter`)
- `script/build_and_run.sh` (`CFBundleURLTypes`)
- [ADR 0039](../decisions/0039-widgetkit-extension-packaging.md)
- [`usage-rings-and-pace.md`](usage-rings-and-pace.md),
  [`settings-surface.md`](settings-surface.md)
- Phase: [`usage-widgets.md`](../plans/phases/usage-widgets.md)
