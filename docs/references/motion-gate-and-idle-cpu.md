# Motion gate and idle CPU — a chained `withAnimation` never stops by itself

- **Applies to:** every repeating or indefinite animation in Rafu, especially
  ones hosted in an `NSHostingView` on a panel (the notch companion), plus the
  periodic timers and the status-bar memory readout.
- **Last verified:** Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), on 2026-10-20, on `main` at 716370a; the leftovers were fixed
  and measured on the same toolchain at 0dce2ae and the commit after it.

## Rule or observed behaviour

### The cause

The notch mascot's "breathing" was a chained `withAnimation` — each completion
started the next leg — driving an `NSHostingView` at 120 Hz. Every frame cost a
full AppKit display cycle plus a `setFrameTransform`, and nothing ever stopped
it: a panel that has been `orderFront`ed still counts as **visible** behind the
lock screen, so the app kept animating a screen nobody could see.

### The gate

`RafuMotionGate` decides whether motion is allowed, from three inputs:

- screen lock — an **initial read** through
  `CGSessionCopyCurrentDictionary()` plus the distributed lock/unlock
  notifications. The initial read matters: the notifications alone leave the gate
  wrong for a process that starts while the screen is already locked.
- display sleep.
- session active.

Per-window occlusion is combined with that and published as
`\.rafuMotionAllowed` in the environment. Gated surfaces: the spinner, the
commit border, the playback bars, the waveform, the mascot, and the
onboarding glow.

### Rules that fell out of the fix

- **Stopping a `repeatForever` animation requires a `disablesAnimations`
  write.** Simply not scheduling the next leg is not enough for an
  already-running `repeatForever`.
- **`TimelineView` is not an idle-safe clock.** With *any* schedule it kept the
  view at roughly 240 updates/s. The idle mascot therefore writes state at
  **15 Hz** instead, and breathes only while engaged; at rest it blinks or
  glances once every 4–6 s and is otherwise still.
- **Measured and rejected:** `.help`, `sizingOptions`, and `drawingGroup` gave
  no gain on this view, and `drawingGroup` was **worse**.
- Periodic timers are coalesced, carry a tolerance, and pause while locked.
- The status bar reports `phys_footprint`, which is the number Activity Monitor
  and the plan's memory budget use — not `resident_size`.

## Why it matters

An idle editor burning ~15 % CPU behind a lock screen is a battery and thermal
defect, and it is invisible in every normal test: the app is "idle", no timer
fires in a test, and the animation only misbehaves on a real display link.

## Reproduction or evidence

Measured with the app idle and the screen locked:

| State | CPU | `RootDisplayList` updates / 10 s |
|---|---|---|
| Before, locked | 14.4–15.7 % | 2891 |
| After, locked | 0.0 % | 0 |
| After, idle visible-equivalent | ≈1.4 % | — |
| After, engaged breathing | 2.3–4.2 % | — |
| Before, engaged (chained animation) | 16–19 % | — |

Raw traces and `top` captures are in the session scratchpad under `perf/`
(before) and `perf2/` (after).

## Verification

```bash
top -l 5 -pid "$(pgrep -x 'Rafu Lightning')" -stats pid,cpu,idlew
xctrace record --template 'SwiftUI' --attach 'Rafu Lightning' --output /tmp/rafu.trace
```

Read `RootDisplayList` update counts from the SwiftUI template. Lock the screen
for the locked measurement; do not infer it from an occluded window.

## Leftovers fixed after 716370a

Measured on a Debug build with the screen locked and a temporary bypass that
forced `\.rafuMotionAllowed` to `true` on the one view under test (the bypass
was never committed). `top -l 50 -s 1`, mean of the last 25 samples:

| Surface | Before | After |
|---|---|---|
| Mascot, working mood | 9.6 % CPU, 13.8 idle wake-ups/s | 2.0 % CPU, 0 idle wake-ups/s |
| `NotchPlaybackIndicator` | 7.2 % CPU | 0.9 % CPU |
| No bypass (gate closed) | 0.0 % | 0.0 % |

- **Working mood.** The trail spin and the antenna bob were chained
  `withAnimation` legs, so the panel rendered every display frame. They are
  now plain state writes at 20 Hz (`RafuMascotWorkingMotion`), from a
  `Task.sleep` loop in the mascot's `.task(id:)`, which already restarts on
  `\.rafuMotionAllowed` and Reduce Motion. Only the blink after every third
  bob is a short animation.
- **Playback bars.** The `TimelineView` is gone. A `.task(id: animating)` loop
  writes the time at 8 Hz with animations disabled.
- **Settings and other windows.** `Settings`, the Workspaces window, the
  Ensemble icon-library panel and the diagram sheet now apply
  `rafuMotionScope()`. The environment default stays `true`; an `@Entry`
  default cannot read the main-actor gate and would not update. A new window
  root, or a new `NSHostingView` or `NSHostingController` that is a window's
  content, must apply the scope itself.
- **Onboarding glow.** The `repeatForever` pulse now restarts on a change of
  `\.rafuMotionAllowed` or Reduce Motion, and stops with a non-animated write.
  The Ken Burns drift is a finite animation and is not gated.
- **Memory timeline.** `MemoryTimeline` reads `phys_footprint` through
  `ProcessMemorySample.displayBytes`, the same figure as the status bar. The
  entry field is still named `residentBytes`.

- **Launcher accept loop.** `LauncherIPCServer` ran its blocking `accept` in
  a `Task.detached`, which held one cooperative-pool thread for the whole app
  session. It now runs on one dedicated `Thread` named "Launcher IPC accept".
  The thread hands each accepted fd to the actor and waits on a
  `DispatchSemaphore` until that registration ends, so connections still
  register one at a time against the live-connection cap. `stopListening()`
  sets an `Atomic<Bool>` stop flag, closes the listener (which ends the
  blocked `accept` with an error), and awaits an `AsyncStream` that the
  thread finishes when it returns. Each connection's reads still run in a
  detached task, bounded by `SO_RCVTIMEO` (5 s).

No known leftovers remain from 716370a.

## Related code, ADRs, and phases

- `RafuMotionGate` and the `\.rafuMotionAllowed` environment key; the notch
  companion views.
- `RafuMascotWorkingMotion` and `NotchPlaybackIndicator` in
  `Sources/RafuApp/Notch/NotchMascotView.swift`; the accept thread in
  `Sources/RafuApp/Launcher/LauncherIPCServer.swift`.
- [`notch-companion.md`](notch-companion.md),
  [`memory-attribution-and-timeline.md`](memory-attribution-and-timeline.md),
  [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md)
- Commits on `main`: 5a0e873, 716370a, 0dce2ae, and the launcher accept-thread commit.
