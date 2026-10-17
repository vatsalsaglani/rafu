# Canvas native boundaries and initial evidence

- Applies to: ADR 0025 and Canvas C0–C5; local macOS workspaces.
- Verified: 2026-10-17, macOS 27.0.1, Apple Swift 6.4, Swift 6.2 package mode,
  strict concurrency, arm64, deployment target macOS 15.

## Rules and observations

C0's three native boundary tests pass without starting a shell, browser load,
external app, or screen capture. One `RafuTerminalView` moved between NSWindows
retains the same parser and negotiated keyboard state. The newline monitor has
one registration while attached and none after detach. This proves native view
transfer only; controller/PTY identity and focus across real Canvas tabs are C3 checks.

ScreenCaptureKit accepts a single-window picker configuration and bounded stream
configuration (960×540, three queued buffers, 10 fps, audio disabled). The Swift
SDK imports `SCContentSharingPickerConfiguration` as a value: bind it with `var`
before setting `allowedPickerModes`. The Objective-C header's class declaration
is not the complete Swift API. These configuration probes do not prove permission,
source-loss, or live stream behavior; C4/C5 use the visible controls for those checks.

A WebKit configuration accepts a nonpersistent data store, disables automatic
JavaScript windows, and requires user action for media playback. No WKWebView or
network request is created by the probe. Actual lifetime and navigation are C4 checks.

Do not infer performance, idle memory, compatibility with untested OS versions,
or permission success from these results. The package still targets macOS 15;
this machine supplies runtime evidence for macOS 27 only.

## Reproduction

```sh
./script/test.sh --filter CanvasFeasibilityTests
./script/test.sh --filter 'Canvas(Document|Persistence|Feasibility)Tests'
```

C0: 3 tests passed. Initial domain/store checkpoint: 11 tests in 3 suites passed,
including parameterized URL checks, stale write detection across two store
instances, corruption isolation, capacity, and payload bounds. Logs are retained
in `/tmp/rafu-canvas-implementation-20261017/` for this local session.

## Persistence boundary

The default Canvas directory uses `RafuAppIdentity.current.applicationSupportRoot()`.
Release and Lightning records remain separate. The app state-root source guard
also applies to new stores; a store must not build its own Rafu root path.

`CanvasPersistenceStore` runs file reads, validation, and encoding on an actor.
The shared instance serializes windows; a nonblocking advisory file lock covers
cooperating app instances. It validates the expected revision before atomic
replacement and uses UUID-only filenames under a workspace digest directory.
Reads reject symlinks/nonregular files and read at most the 2 MiB cap plus one
byte. Corrupt boards are reported separately from valid siblings. No source
file, command, terminal output, credential, cookie, or captured frame is stored.

Related: `Sources/RafuApp/Canvas/`, `Tests/RafuAppTests/Canvas/`, ADR 0025,
`docs/plans/phases/workspace-canvas.md`, ADR 0023 and 0024.
