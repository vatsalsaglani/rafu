# Voice `show_view` and argument-delta streaming

- Applies to: `Sources/RafuCore/Voice/VoiceLiveEvents.swift`,
  `Sources/RafuApp/Voice/VoiceSession.swift` (the "View streaming" block),
  `Sources/RafuApp/Voice/VoiceToolExecutor+Views.swift`, and
  `GeneratedViewStreamSession`
  ([ADR 0035](../decisions/0035-voice-through-gpt-live.md) amendment,
  [ADR 0036](../decisions/0036-generated-views-on-the-ensemble-board.md)).
- Last verified: Swift 6.4.2, macOS 27, 2026-11-08 (code and unit tests). The
  orphan rule and the stream undo collapse describe the fix round on branch
  `fix/voice-mic-allow`, not merged when this note was written. **Whether
  GPT-Live sends argument deltas at all is not verified.** The measurement is
  pending the user's report.

## Rule or observed behavior

### The two events

Both arrive inside `response.event` and decode in `VoiceLiveServerEvent`:

- `response.output_item.added` with `item.type == "function_call"` gives
  `functionCallStarted(itemID, callID?, name)`. `callID` may be absent here.
  Other item types decode to `.other`.
- `response.function_call_arguments.delta` gives
  `functionCallArgumentsDelta(itemID, delta)` (fields `item_id`, `delta`).

The finished call is the existing `response.output_item.done` event
(`functionCall(callID, name, argumentsJSON)`).

### Hand-off order

1. Started: the session records an `ArgumentStream` for the item (at most 16 at
   once).
2. Each delta: the session counts it and, for `show_view` only, keeps the text
   until it knows the title. This runs on the main actor at once, not behind the
   call chain, so the skeleton appears while the model still speaks.
3. Title window: the session decides when the title string is complete, or a spec
   key (`root`, `elements`, `state`) has begun, or 512 bytes have arrived. It then
   asks `VoiceToolExecutor.beginShowView` for a skeleton card (counts one
   admission against the 30-per-minute limit; returns nothing, and the final call
   then creates the card without streaming, when no Ensemble shows, Agent control
   is Off, no view host is installed or the host refuses), and pushes the held
   text, then every later delta, into the card's stream. A `title` inside an
   element prop is never the card title.
4. Finished: `functionCallFinished` matches the call to its item by `call_id`,
   else by the oldest unmatched item with the same name, marks the stream
   `finished`, and returns the timeline measure. `showView` finds the handle by
   call id and calls `finish`.
5. Response completed: `cancelOrphanViewStreams` cancels the skeleton of every
   stream that is not `finished`.
6. Session close or a new session: `cancelViewStreams` cancels every skeleton;
   nothing is saved.

### Orphan rule (corrected)

An orphan is a started call whose done event never arrived by the end of the
response. The rule tests `ArgumentStream.finished`, which only the done event
sets. The earlier test used the presence of a `callID`, which is wrong because a
started item can carry its `call_id` early.

### Measure

The timeline row of every `show_view` call ends with "deltas: N, size"
(for example "deltas: 14, 3.1 KiB"), and "deltas: 0" when none arrived. It is
counts only; no spec text is logged or shown. **Measured delta count: pending the
user's report.** If the backend never sends deltas, the code stays (it is
harmless) and this note should record "no deltas observed with the backend model
on that date".

## Why it matters

The skeleton makes a long view feel immediate, but only if the backend streams
arguments. A skeleton that is never finished or cancelled would stay on the board
and in the undo history, so the cancel paths matter as much as the happy path.

## Reproduction or evidence

`Tests/RafuCoreTests/Voice/VoiceLiveEventsTests.swift` (both events, and an
`output_item.added` of another type is `.other`);
`Tests/RafuAppTests/Voice/VoiceShowViewTests.swift`. Test counts and the real
measurement were not part of the handoff.

## Verification

- `swift test --filter VoiceLiveEvents`, `--filter VoiceShowView`
- `./script/test.sh` and `./script/test.sh --no-parallel`
- Manual (Rafu Lightning only): voice in Ask mode, "show me failing tests by
  suite"; read "deltas: N" in the Voice Timeline popover and report it.

## Related code, ADRs, and phases

- [`gpt-live-protocol.md`](gpt-live-protocol.md) (event table, tool flow)
- [`generated-view-card-and-state.md`](generated-view-card-and-state.md) (undo
  collapse)
- Phase: [`../plans/phases/voice-control.md`](../plans/phases/voice-control.md)
