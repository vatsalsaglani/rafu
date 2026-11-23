# Meeting transcript quality: echo words, turn cuts and talk share

- Applies to: `Sources/RafuCore/Meetings/Transcript/` (`MeetingEchoWordMarker`, `MeetingTurnRules`,
  `MeetingTurnBuilder`, `MeetingWordSpeakerAssigner`, `MeetingLiveTurnAssembler`, `MeetingSpeakerStats`),
  `MeetingTranscriptAssembly.assemble` in `Sources/RafuCore/Meetings/Processing/MeetingProcessingPlan.swift`, and the
  optional field `speechSeconds` on `MeetingTurn`.
- Last verified: 2026-11-23. The handoff gave no Swift or macOS version for this package. The numbers below come from
  one real meeting (6 min 17 s, built-in microphone and speakers, Teams) that was measured before the
  change; the new thresholds are design values checked by unit tests on made-up words only.

## Rule or observed behavior

**Echo is marked for each word, by text match, with no loudness test.**

1. `outputWasSpeakers == false` (headphones) or no "Them" words: no word is echo.
2. A "Me" word matches one unused "Them" word with the same normalised text when the start times differ by at most
   1.5 s. The nearest in time wins; a tie goes to the earlier word. Each "Them" word is used once. A word whose
   normalised text is empty never matches.
3. A stretch is a run of "Me" words with no pause between them. A stretch of fewer than 3 words is never echo.
4. In a stretch, a matched word is echo when at least 50 percent of the words from 3 before to 3 after it are
   matched. An unmatched word is echo at 60 percent.
5. A run of 1 or 2 non-echo words with echo on both sides in the same stretch is echo.

The marker returns its flags in the input order of the "Me" words. No text is deleted: echo words stay in the turns
with `isEcho == true` and the interface hides them by default.

**Turns are cut by one shared function** (the final builder and the live assembler use it).

- An effective word end is `min(end, start + 0.8 s)`.
- A turn is cut before a word when the speaker changes; or the echo flag changes (the "Me" track); or the gap from
  the effective end of the last word is at least 1.0 s; or the turn is at least 20 s long and the last word ends
  with `.`, `?` or `!`, or the gap is at least 0.5 s; or the next word would take the turn past 60 s.
- A turn ends at the effective end of its last word (a word end is capped at 0.8 s after its start).
- Each new turn stores `speechSeconds`, the sum of `min(end - start, 0.8)` over its words. Old turns decode with
  `speechSeconds == nil`.

**A "Them" word with no speaker segment joins the nearest speaker.** When at least one valid segment exists, a word
with no overlap takes the nearest segment at any distance (a tie goes to the earlier one). `.them` is the label only
when there are no valid segments. The old 0.5 s limit (`nearestSegmentSeconds`) is gone.

**Talk share is computed from stored turns** by `MeetingSpeakerStatsRule.stats(for:)`.

- A turn counts `speechSeconds`, or its length when `speechSeconds` is nil (then `isEstimated` is true). Echo turns
  are not counted.
- A speaker is shown at 2 s of speech or more. If no speaker reaches 2 s, all are shown. Shares of the shown speakers
  sum to 1.
- `totalSpeechSeconds` counts all speakers, shown or not. If every shown speaker has 0 s, every share is 0. A speaker
  with echo turns only is listed with 0 s and is not shown.

## Why it matters

- With built-in speakers, the far-side sound enters the built-in microphone. The user's talk share came out far too
  high, and the "2 turns for 6 minutes" Nemotron result hid the structure.
- **Nemotron word ends.** `MeetingTokenWordGrouper.words`
  (`Sources/RafuCore/Meetings/Worker/MeetingWorkerWords.swift`) ends each word at the next word's start, so the gap
  between two words is always 0. A rule that cuts only at a 1.0 s gap never cuts. Nemotron also gave 0 sentence ends
  in 773 words. The 0.8 s word cap and the cut at 20 s and at 60 s exist for this. The 0.8 s cap is also what makes
  `speechSeconds` a speech time, not a turn length.
- Echo cannot be told apart by level: the "Them" sound was as loud as the user's voice.

## Reproduction or evidence

One real meeting, 6 min 17 s, built-in microphone and speakers, Teams. Numbers as recorded in the advisor brief,
measured before the change.

| Observation | Value |
|---|---|
| Level correlation Me to Them, 37 windows of 10 s | 0.958 |
| Mean level when Them is active | Me -21.9 dBFS, Them -23.9 dBFS |
| Windows where Them is active | 36 of 37 |
| Windows where Me is clipped (0.0 dBFS) | 12 of 37 |
| Nemotron | 2 turns; Me 942 words, 751 of them in Them = 79.7 percent (just under the old 80 percent rule, so no mark) |
| WhisperKit | 37 visible turns, 7 hidden echo turns; visible Me 578 words, 418 (72 percent) in near Them turns |
| Me word share | 44 percent with echo counted; about 18 percent with echo words removed |
| Late echo turns | two "Me" echo turns began 8 s and 11 s after the "Them" turn (outside the old 2.0 s window) |
| Mixed "Me" turns | 94 words with 47 matched; 66 words with 23 matched |
| A real "Me" turn | 68 words, 1 matched |
| Stray "Them" speaker | 2 turns with 3 words beside one real speaker with 68 segments |
| Longest WhisperKit turns | 128, 111 and 106 words, each with 3 to 5 sentence ends |

Voice processing was rejected as the cure: the decision about meeting capture
([`0048`](../decisions/0048-meeting-capture-and-on-device-speech.md)) records that it stops the call-audio tap.

**Words and segments are not stored.** The store keeps turns only (`turns.jsonl`). A meeting that was processed
before this change keeps its old turns: stats work for it at load (with `isEstimated`), but the word echo mark, the
stray-word join and the new cuts need the words. The user gets them through "Make the text again".

**Implementor choices that the advisor brief left open**

- A turn ends at the effective end of its last word (cap 0.8 s).
- The 60 s rule cuts before the word that would pass 60 s.
- The echo flags are returned in the input order of the "Me" words, not in clock order.
- `totalSpeechSeconds` counts all speakers. A speaker with only echo turns is listed with 0 s and is not shown.
- When all shown speakers have 0 s, all shares are 0.

**Swift Testing trap met here.** `#expect(x.allSatisfy(\.flag))` does not compile: the macro turns the key path into a
call that can rethrow. Write `allSatisfy { $0.flag }`. (The general trap is in
[`repository-policy-tests.md`](repository-policy-tests.md).)

## Verification

- Unit tests on made-up words with binary-exact times, in `Tests/RafuCoreTests/Meetings/Transcript/` and
  `Tests/RafuCoreTests/Meetings/Processing/MeetingProcessingRulesTests.swift`. They cover echo for each word, a late
  start, a long turn at 79.7 percent, mixed turns, headphones, a two-word answer, one match for each "Them" word,
  stray words, the Nemotron shape (word end equals next start), cuts at 20 s and 60 s, stable turn ids and the stats
  rules.
- Both test modes passed on `main` (the handoff gave 4,495 app tests and 1,117 core tests; it did not give the count
  for each mode).
- Not verified: the thresholds on a re-processed real meeting. Use "Make the text again" on the meeting above and look
  at the hidden echo turns and the talk shares.

## Related code, ADRs, and phases

- Decision about meeting capture and on-device speech
  ([`0048`](../decisions/0048-meeting-capture-and-on-device-speech.md)), amendment "the echo mark is set for each
  word".
- [`meeting-audio-capture.md`](meeting-audio-capture.md) (echo on the Mac speakers).
- Phase document [`meetings.md`](../plans/phases/meetings.md).
