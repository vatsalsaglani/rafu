# SwiftPM binaries were stamped with SDK 15.0; the build script restamps them

- Applies to: every Mach-O staged by `script/build_and_run.sh` (app, `rafu` CLI,
  `rafu-agent-events`, the `RafuWidgets` appex, `MediaRemoteAdapter.framework`);
  `script/sdk_link_flags.sh`, `script/check_sdk_stamp.sh`, `script/verify.sh`;
  `SDKStampScriptTests`
- Last verified: Swift 6.4.2, Xcode with macOS 27.2 SDK (26B118), Darwin 27.2.0,
  Mac17,13, 2026-11-15. Merge "real SDK stamp, optional signing identity",
  commit 2968d3a. Serial suite on `main` after this merge: 466 tests in 33 suites
  and 3729 tests in 302 suites, passed.

## Rule or observed behavior

Every Mach-O built by SwiftPM's Swift Build backend had `LC_BUILD_VERSION`
`sdk 15.0`, equal to the deployment target, and not the selected SDK 27.2. The
system then treats Rafu as linked against the macOS 15 SDK ("linked on or after"
behaviour), including for WidgetKit.

**Cause (proven).** Swift Build links by calling the real `clang` with
`--sysroot <SDK>`. That `clang` cannot read `SDKSettings.json` from `--sysroot`
and falls back to `-platform_version macos 15.0.0 15.0.0`. Plain `swiftc` through
the `/usr/bin` `xcrun` shim stamps correctly, because the shim exports `SDKROOT`.

**Fix.** `script/sdk_link_flags.sh <min>` prints

```
-Xlinker -platform_version -Xlinker macos -Xlinker <min> -Xlinker <sdk>
```

with `<sdk>` from `xcrun --show-sdk-version` at build time. Never hard-code it;
CI stamps its own SDK. A later `-platform_version` wins in `ld`.
`build_and_run.sh` passes the flags to all four `swift build --product` calls
(a relink only). `script/check_sdk_stamp.sh` fails when the stamped sdk major is
below the selected SDK major, or when minos is not `RAFU_EXPECT_MINOS`.
`RAFU_EXPECT_MINOS` is `MIN_SYSTEM_VERSION`, which must equal Package.swift
`.macOS(.v15)`. `check_sdk_stamp.sh --self-test` uses a fake `vtool` and runs in
`verify.sh`. `SDKStampScriptTests` has 3 tests.

**Dead ends.** `SDKROOT=... swift build` does not reach the link step.
`-Xlinker -sdk_version` is obsolete.

## Why it matters

A wrong sdk stamp changes system behaviour silently (compatibility behaviours,
WidgetKit). No build error appears. Without the check, a toolchain change could
bring the stamp back to 15.0.

## Reproduction or evidence

Repro: `clang h.o --sysroot MacOSX27.2.sdk --target=arm64-apple-macos15.0` gives
`sdk 15.0`.

Evidence with `vtool`: `RafuLightning`, the `rafu` CLI, `rafu-agent-events` and
the `RafuWidgets` appex were all minos 15.0 sdk 15.0 before; now minos 15.0 sdk
27.2. `MediaRemoteAdapter.framework` is sdk 27.2.

Side effects:

- A plain `swift build` or `swift test` outside the script still stamps 15.0.
  Only the staged bundle matters.
- A benign cold-build warning: `JSONRenderMacros: ld: warning: passed two min
  versions (14.0, 15.0) for platform macOS. Using 15.0.` (the macro host tool).

## Verification

```bash
./script/check_sdk_stamp.sh --self-test
swift test --filter "SDKStampScriptTests"
vtool -show-build <staged Mach-O>      # read LC_BUILD_VERSION: minos and sdk
```

Where `check_sdk_stamp.sh` runs on a real staged bundle (as opposed to its
self-test in `verify.sh`) was not stated in the handoff.

## Related code, ADRs, and phases

- `script/sdk_link_flags.sh`, `script/check_sdk_stamp.sh`,
  `script/build_and_run.sh`, `script/verify.sh`
- [`build-and-run.md`](build-and-run.md) (signing and the widget gallery check)
- [ADR 0039](../decisions/0039-widgetkit-extension-packaging.md)
- [`usage-widgets.md`](../plans/phases/usage-widgets.md)
