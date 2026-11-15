# Usage widgets (WidgetKit)

## Status

**Active (2026-11-15).** The user approved the widget designs. Packaging and data
path decision: [ADR 0039](../../decisions/0039-widgetkit-extension-packaging.md).

| Step | State |
|---|---|
| W0 packaging (SwiftPM `RafuWidgets` appex assembled by `build_and_run.sh`, signing order, snapshot read) | Done, except the widget gallery check (see below) |
| W1 | Running (2026-11-15) |
| W2 | Pending |
| W3 | Pending |
| W4 | Pending |

The scope of W1 to W4 was not given in the handoff; the lines above record state
only. The daily usage log is part of the plan, with no further detail recorded.

## Work log

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
