# Memory footprint reading and timer coalescing

- **Applies to:** the status-bar and Resources memory readout
  (`ProcessMemorySampler`, `ProcessMemorySample.displayBytes`,
  `MemoryTimeline`), and every periodic wait in the app (notch usage timer,
  language-server watchdog, agent activity clock, status-bar memory loop).
- **Last verified:** Apple Swift 6.4, macOS 27.0.1, on 2026-10-20, at 716370a
  (timeline change at 0dce2ae).

## Rule or observed behaviour

### Show `phys_footprint`, not resident size

- `ProcessMemorySampler` reads `phys_footprint` through `task_info` with the
  `TASK_VM_INFO` flavor (`footprintBytes`, `nil` if the call fails).
  `displayBytes` is the footprint, else `resident_size`. The status bar, the
  Resources popover, and `MemoryTimeline` show `displayBytes`.
- `resident_size` falls when the kernel compresses pages. On an idle, locked
  Rafu Lightning, `ps` reported 89 MB resident while `footprint(1)` reported
  117 MB. Activity Monitor's Memory column and the idle-memory budget in
  `AGENTS.md` use the footprint, so the UI must too. User-visible text says
  "footprint".
- `MemoryTimelineEntry` keeps its `residentBytes` field name; the value is now
  the footprint (`displayBytes`).

### Coalesce periodic wake-ups, and stop them while locked

- `Task.sleep(for:tolerance:)` and `Timer.tolerance` let the system merge
  wake-ups. Values in use: notch usage timer 180 s with 10 % tolerance;
  language-server watchdog 5 s with 20 %; agent activity clock 30 s with
  about 17 % (interval / 6); status-bar memory loop 5 s with 1 s.
- The status-bar memory loop is a `.task(id:)` keyed on
  `RafuMotionGate.isScreenActive`. It ends when the screen locks or the
  displays sleep and reads at once when the task restarts. The usage timer
  skips its refresh in the same states.
- New repeating waits should set a tolerance and, if the result is visible
  only on screen, key on the gate.

## Why it matters

A bare `Task.sleep` or `Timer` wakes the CPU at its exact time. Many such
timers prevent idle power states. A resident-size readout under-reports
memory, so the 150 MB budget could look met when it is not.

## Reproduction or evidence

`ps -o rss= -p <pid>` against `footprint <pid>` on a locked, idle Rafu
Lightning. Unit test: `Tests/RafuAppTests/ProcessMemorySamplerTests.swift`.

## Verification

```bash
footprint "$(pgrep -x 'Rafu Lightning')" | head
swift test --filter ProcessMemorySamplerTests
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Support/ProcessMemorySampler.swift`,
  `Sources/RafuApp/Views/WorkspaceStatusBar.swift`
- [`motion-gate-and-idle-cpu.md`](motion-gate-and-idle-cpu.md),
  [`memory-attribution-and-timeline.md`](memory-attribution-and-timeline.md),
  [`memory-caps-and-pressure.md`](memory-caps-and-pressure.md)
