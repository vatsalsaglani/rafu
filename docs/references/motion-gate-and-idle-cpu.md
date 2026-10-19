# Motion gate and idle CPU — a chained `withAnimation` never stops by itself

- **Applies to:** every repeating or indefinite animation in Rafu, especially
  ones hosted in an `NSHostingView` on a panel (the notch companion), plus the
  periodic timers and the status-bar memory readout.
- **Last verified:** Apple Swift 6.4 (swiftlang-6.4.0.34.1), macOS 27.0.1
  (26A434), on 2026-10-20, on `main` at 716370a.

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
commit border, the playback bars, the waveform, and the mascot.

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

## Known leftovers (not fixed in 716370a)

- The working-mood indicator still spins at 120 Hz.
- `NotchPlaybackIndicator` keeps a `TimelineView` running while music plays.
- The onboarding glow is ungated.
- Settings windows default to motion-allowed.
- The memory timeline still records `resident_size`, not `phys_footprint`.
- `LauncherIPCServer`'s accept loop runs on the cooperative pool.

## Related code, ADRs, and phases

- `RafuMotionGate` and the `\.rafuMotionAllowed` environment key; the notch
  companion views.
- [`notch-companion.md`](notch-companion.md),
  [`memory-attribution-and-timeline.md`](memory-attribution-and-timeline.md),
  [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md)
- Commits on `main`: 5a0e873, 716370a.
