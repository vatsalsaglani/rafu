# Microphone permission: when macOS lists the app

- Applies to: `VoiceMicrophonePermission` in
  `Sources/RafuApp/Voice/VoiceAudioIO.swift`, the voice session start, and
  Settings ▸ Voice (`VoiceSettingsSection.swift`)
  ([ADR 0035](../decisions/0035-voice-through-gpt-live.md)).
- Last verified: macOS 27, 2026-11-08. Rules about the "Allow Microphone…" button
  describe branch `fix/voice-mic-allow`, not merged when written. The button and
  the resulting Privacy listing were **not** checked by a person yet (manual
  check in the phase document).

## Rule or observed behavior

- macOS lists an app under System Settings ▸ Privacy & Security ▸ Microphone only
  after the app has called `AVCaptureDevice.requestAccess(for: .audio)`. Before
  that call the app is not in the list, so a button that only opens System
  Settings cannot help.
- Rafu's voice session asks for the microphone only after it has read the OpenAI
  key. A user who never saved a key, or who opens Settings first, therefore never
  triggered the request.
- Settings ▸ Voice shows **Allow Microphone…** when the status is "not asked"
  (`AVCaptureDevice.authorizationStatus` is `.notDetermined`). It calls
  `VoiceMicrophonePermission.request()` and then re-reads the status. When the
  status is allowed or denied, the button is "Open System Settings".
- `request()` asks once; a later call returns the stored answer at once.

## Why it matters

A user who denied nothing could still find no Rafu entry to switch on. The button
makes the system prompt reachable without a voice session.

## Reproduction or evidence

Not reproduced by an agent: the permission prompt needs a person (no synthetic
input). The status mapping is covered by the logic in `VoiceMicrophonePermission`;
the Privacy listing is a manual check.

## Verification

Manual (Rafu Lightning only): with the microphone "not asked", press Allow
Microphone… in Settings ▸ Voice, answer the system prompt, then confirm Rafu
Lightning appears under Privacy ▸ Microphone.

## Related code, ADRs, and phases

- `VoiceAudioIO.swift`, `VoiceSettingsSection.swift`, `VoiceSession.swift`
- [`gpt-live-protocol.md`](gpt-live-protocol.md)
- Phase: [`../plans/phases/voice-control.md`](../plans/phases/voice-control.md)
