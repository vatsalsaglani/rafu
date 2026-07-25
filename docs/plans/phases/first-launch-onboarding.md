# The Unfolding — Rafu's first-launch experience

- **Status:** Design proposal / screenplay (2026-07-26). No branch, no
  owned paths, no ADR yet. Shipping this requires an ADR covering bundled
  media size, sound, and the motion budget (see "Open decisions").
- **What this is:** the complete screenplay for the one-time experience a
  user gets the first time they open `Rafu.app` — scene by scene, with
  final copy, motion direction, honest fallbacks, and generation-ready
  prompts for every video, image, and music asset.
- **The bar:** the user should feel like they are opening a gift, and
  should want to show someone. Not because it is loud — because it is
  *made*. One person, one machine, ninety seconds, and at the end the
  ribbon becomes the caret.

---

## Why cloth (the conceit)

Rafu's naming has always been textile: the product was nearly called
**Darn**, its light theme nearly **Linen**; today's themes are **Indigo**
(the dye) and **Khadi** (handspun cloth). The palette agrees — Indigo is
a dye-vat night (`#10141C`) shot through with one gold thread
(`#E3A857`); Khadi is woven bone (`#F1EDE3`) with an ochre thread
(`#A2701F`).

So the onboarding is a **weaving**. A single thread appears in the dark,
and over ninety seconds it weaves the workbench — the editor, the
terminal, the agents, the themes — until the final pull of the thread
becomes the blinking caret in the user's first real buffer. The gift's
ribbon becomes the tool's heartbeat.

Every dev tool ships a carousel. Nobody else can ship a loom.

## The two cuts

The film exists in two grades, chosen automatically by the system
appearance (the user asked for nothing yet; we match the room):

| | **The Indigo Cut** (dark mode) | **The Khadi Cut** (light mode) |
|---|---|---|
| World | Indigo-dyed night `#10141C` | Handwoven bone `#F1EDE3` |
| The Thread | Gold `#E3A857` | Ochre `#A2701F` |
| Ink / text | `#E7EAF2` | `#2B2F3A` |
| Feel | A lantern-lit workshop at 2am | A sunlit weaver's table |

Same screenplay, same timings, same copy. Two asset sets.

## Principles (the guardrails the drama lives inside)

1. **Skip is sacred.** A quiet "Skip intro" sits bottom-left of every
   frame from second one, plus ⎋. Skipping jumps to the 60-second
   compact setup (§ The Skip Cut) — never to a dead end, never to guilt.
2. **Every scene teaches something true.** No vibes-only frames. Each
   scene's claim is checkable in the product five minutes later.
3. **Sound is a gift declined by default.** The film is scored, but
   plays silent unless the user taps the "▶ Play with sound" chip in the
   cold open. Autoplaying audio at first launch is how you get deleted.
4. **Native to the bone.** SwiftUI + AVKit playing bundled H.265 loops
   and SwiftUI/Metal shaders. No web view, no network, no telemetry —
   the intro must live by the same rules the product brags about.
5. **Honest machines only.** The agent-discovery scene runs the *real*
   adapter probes. A CLI that isn't installed stays dim. We never
   animate a lie.
6. **Reduce Motion is a first-class cut**, not a punishment: crossfades
   between the same composed stills, full copy, full function.
7. **Replayable.** Help ▸ "Play the intro again." That is the entire
   share strategy: people demo what they can summon.
8. **Total runtime:** ~90 s if you savor it, ~40 s if you hold ⏎, ~8 s
   if you skip. The film respects impatience as a valid review.

---

# THE SCREENPLAY

*(Copy in quotes is final-candidate. Stage directions in italics.
Timings assume the savoring viewer.)*

---

## SCENE 0 — "The Knot" (0:00–0:06) · cold open

*Absolute dark (Indigo Cut) or absolute bone (Khadi Cut). No chrome, no
window controls yet — a borderless full-content window. One small knot
of gold thread sits center-frame, almost too small, like something you'd
find in a pocket. It breathes — a 2% scale sway, 6-second period.*

*Bottom-left, at 40% opacity:* `Skip intro (esc)`
*Bottom-right, same weight:* `▶ Play with sound`

*No copy for three full seconds. Confidence is silence.*

*Then, small, beneath the knot:*

> **"Rafu"** — *and under it, lighter:* "n. — to mend, with thread."

*The knot gives one soft pull, as if someone off-screen tugged it, and
the loose end shoots off-screen right. Hard cut on the pull.*

**ASSET V0 — the knot.** Video, 8 s loop + one 1 s "pull" out-cut,
2048×1280, H.265, silent. Generation prompt (Indigo grade):

> Macro photography of a single small knot of luminous gold silk thread
> (#E3A857) resting on deep indigo-black handwoven fabric (#10141C),
> extreme close-up, shallow depth of field, the thread faintly glowing
> like an ember, subtle fabric texture visible in the darkness, the knot
> breathing almost imperceptibly, then one end of the thread suddenly
> pulled off-frame to the right in a fast elegant whip. Cinematic
> lighting, single warm practical light source, photorealistic, no text,
> no hands, no logos. Slow 8-second meditation then the pull.

*Khadi grade: same prompt with "ochre cotton thread (#A2701F) on
sunlit undyed handspun khadi cloth (#FAF7F0), soft morning light."*

**SFX:** one felted *pluck* on the pull (the only sound cue that also
plays in silent mode: it doesn't — nothing plays in silent mode; this is
the first payoff for the sound-enablers).

**REDUCE MOTION:** the knot as a still; the pull becomes a crossfade.

---

## SCENE 1 — "The Loom" (0:06–0:22) · title sequence

*The pulled thread streaks through darkness and begins to WEAVE — fast,
confident passes, left-right, like a shuttle. Where it crosses itself,
structure appears: first a rectangle (a window), then vertical seams (a
sidebar, an editor, a terminal pane), then tiny warp lines that resolve
into lines of text made of thread. It is unmistakably building THE
APP — the actual Rafu layout, woven.*

*Three lines of copy, timed to three shuttle passes, each holding ~3 s:*

> "Software is fabric."

> "Yours has loose threads — a repo here, an agent there, a terminal
> screaming somewhere."

> "Rafu is where you mend."

*The woven window settles. It is beautiful but clearly cloth — we are
not in the real app yet. The thread exits frame-right, impatient.*

**ASSET V1 — the weaving of the workbench.** Video, 14 s, 2560×1600,
H.265. Generation prompt (Indigo grade):

> A single glowing gold thread (#E3A857) weaving itself at speed through
> deep indigo darkness (#10141C), like a loom shuttle with a mind of its
> own, leaving luminous woven structure behind: first the rectangular
> outline of a desktop application window, then interior seams dividing
> it into a narrow left sidebar, a large editor area, and a lower
> terminal strip, then dozens of fine horizontal thread-lines inside the
> editor area suggesting lines of code. The geometry is precise and
> architectural but the material is unmistakably textile — visible
> fiber, slight fuzz, warm glow at every intersection. Dark elegant
> cinematic macro look, no text, no hands, no UI icons, no logos.
> Camera slowly pushes in 10%.

**MUSIC enters here** (if enabled) — see § The Score.

**REDUCE MOTION:** three composed stills of the weave at 25% / 60% /
100% completion, crossfaded under the same copy.

---

## SCENE 2 — "Three Truths" (0:22–0:40) · the manifesto carousel

*The woven window drifts to the background at 20% opacity and becomes
the backdrop for three cards, advanced by ⏎/→/click, auto-advancing at
6 s each. The thread underlines each card's headline as it arrives —
a hand-drawn stroke, not a UI line. This is the carousel the user asked
every app for and no app made worth watching.*

**Card 1 — NATIVE**

> **"No web view in a trench coat."**
> "Rafu is real macOS — real windows, real menus, your keyboard
> shortcuts, your accessibility settings. The editor is TextKit. The
> terminal is a terminal. The only thing Electron about it is that we
> just said Electron."

**Card 2 — PRIVATE**

> **"Your code doesn't phone home. It doesn't even have our number."**
> "No account. No telemetry. Keys live in your Keychain, diffs go to a
> model only when *you* press the button, and 'offline' is a place Rafu
> works, not an error state."

**Card 3 — QUIET**

> **"Built to idle under 150 MB."**
> "That's the budget we hold ourselves to — roughly one browser tab's
> breakfast. Parsing runs only on open files. Nothing polls. The fans
> stay bored."

**ASSET I1/I2/I3 — card backdrops.** Three stills, 2560×1600, subtle
enough to sit at 20%. Generation prompt (shared base, Indigo):

> Extreme macro of indigo-black handwoven fabric (#10141C, weave texture
> clearly visible), a few gold threads (#E3A857) running through it in a
> precise geometric path, photographed like a luxury textile catalog,
> single warm side-light, deep shadows, elegant and calm, no text, no
> objects, no hands. — *I1 variant:* the gold path traces a subtle
> rectangular window outline. *I2 variant:* the gold thread forms a
> small closed loop like a keyhole. *I3 variant:* one thin gold thread,
> nearly still, across an expanse of dark cloth.

---

## SCENE 3 — "The Dye Bath" (0:40–0:58) · choose your cloth

*The first real choice. Seven folded cloth swatches fan out like fabric
samples on a table — each one is a THEME, rendered as a miniature woven
editor in that theme's true colors: Indigo, Khadi, Dracula, GitHub Dark,
GitHub Light, Notion Dark, Notion Light. The swatch matching the system
appearance is already gently lifted.*

> **"Pick your cloth."**
> "We matched the room already — you're on dark mode, so Indigo's up
> front. Change your mind whenever; the dye's not permanent."
> *(Light-mode users get: "…you're on light mode, so Khadi caught the
> sun first.")*

*INTERACTION: hovering a swatch dips the ENTIRE screen through that
theme — a liquid "dye ripple" that sweeps from the swatch outward,
recoloring the woven backdrop, the copy, the thread itself (Dracula dyes
the thread purple `#BD93F9`; GitHub Dark dyes it blue `#2F81F7`…).
Selecting commits with a satisfying cloth-settling motion. This single
interaction is the most shareable ten seconds of the film.*

**IMPLEMENTATION NOTE:** the dye ripple should be a SwiftUI/Metal
shader (a radial color-map sweep with a soft turbulence edge), not
video — it must react to live pointer position and any of 7 themes.
Video cannot do interactive. The shader is the scene.

**REDUCE MOTION:** swatch hover recolors via 0.2 s crossfade, no sweep.

---

## SCENE 4 — "The Ensemble" (0:58–1:20) · agent discovery, live

*The woven window recedes; seven BOBBINS descend on threads and hang in
a loose arc, each carrying a real vendor mark (the `agent-*.svg` set):
Claude Code, Codex, OpenCode, Cline, Kimi, Gemini, Cursor. As the scene
plays, Rafu runs its REAL adapter probes. Each CLI found on this machine:
its bobbin lights, gives one pendulum swing, and its thread ties into
the loom. Not installed: the bobbin stays dim and matte — present,
honest, unlit.*

> **"You already hired the agents. We just found their desks."**

*Then, as results land, a live-typed line each, e.g.:*

> "Claude Code — found, logged in. It's practically tapping its foot."
> "Codex — found. Say the word."
> "Kimi CLI — not installed. The bobbin stays grey; we don't fake
> headcount."

*Closing line, smaller:*

> "Rafu conducts them — separate worktrees, human gates, one graph.
> Your keys stay theirs. Your merges stay yours."

*If ZERO agents are found:* the arc stays calm and the copy flips —
"None yet. That's fine — Rafu is a lovely place to just write code.
The bobbins will wait." *(No sadness. No upsell.)*

**ASSET V2 — bobbins descending.** Video, 8 s, 2560×1600 (icons and
light-up states are composited live in SwiftUI over the video; the
video is only the descent). Prompt (Indigo):

> Seven elegant wooden thread bobbins wrapped in gold thread (#E3A857)
> descending slowly on single threads from above into frame, coming to
> rest in a gentle arc, deep indigo-black woven fabric background
> (#10141C), warm single-source lighting, each bobbin swaying slightly
> as it settles, macro cinematic depth of field, photorealistic, no
> text, no logos, no hands.

**SFX:** a soft wooden *tick* per discovery; a warmer *pluck* when one
lights.

---

## SCENE 5 — "The Signature" (1:20–1:38) · AI, usage, consent

*One bobbin of a different color — the ink bobbin — lowers to
center. This is the provider setup for commit drafting, and the tone
goes quieter, because this is the consent scene and we mean it.*

> **"One key. Your Keychain. Our restraint."**
> "Add an AI provider and Rafu will draft commit messages from your
> staged diff — when you press the button, never before. The key lives
> in the macOS Keychain. We can't read it from here, and we like it
> that way."

*Fields: provider picker, key field, a [Test] button that does one real
round-trip and reports plainly. Below, a separate quiet toggle:*

> "Also meter my agent usage locally — so the Ensemble can tell you
> what a run cost. Reads local usage data only. Fabricates nothing."

*The LATER button is styled exactly as prominently as SAVE:*

> "Later" — *with a caption:* "Everything above lives in Settings.
> Nothing in Rafu sulks when skipped."

---

## SCENE 6 — "The Handle" (1:38–1:48) · the CLI

*The thread stitches four letters directly onto the cloth in a
monospaced hand:* `rafu`

> **"Type `rafu` anywhere. Arrive here."**
> "One symlink in `~/.local/bin` — added only if you say so — and
> `rafu .` opens any folder in Rafu, `rafu file:120` lands on line 120.
> Your terminal and your editor stop pretending they're strangers."

*Buttons: [Install the command] · [Later]. Install runs the real
symlink install and confirms with the thread tying a tiny bow. Yes, a
bow. It's a gift; we're allowed exactly one.*

---

## SCENE 7 — "The First Stitch" (1:48–2:00) · finale

*Everything woven so far — window, seams, bobbins, swatch — pulls
TIGHT. The thread sweeps once around the frame and the cloth becomes
crisp: the woven window resolves into the REAL Rafu window, pixel for
pixel, in the user's chosen theme. Window chrome arrives. The traffic
lights blink on. The loom is gone; the workbench remains.*

*The thread's last inch drops into the empty editor and stands up
vertically —*

*— and becomes the caret. Blinking. Gold in Indigo; ochre in Khadi.*

> **"Enough about us."**
> "Open something."

*Buttons: [Open Folder…] · [Clone a Repository…] · [Just let me type].
Below, at whisper volume:*

> "Encore anytime: Help ▸ Play the intro again."

**ASSET V3 — the resolve.** Video, 6 s, 2560×1600 — the tightening
sweep only; the final frame must match a real screenshot composition so
SwiftUI can cross-dissolve from video to the live window. Prompt:

> A luminous gold thread (#E3A857) sweeping one full elegant orbit
> around a woven fabric depiction of a desktop app window on indigo
> black cloth (#10141C), and as it completes the orbit every woven line
> pulls taut and sharpens, fabric texture smoothing into clean flat
> geometry, the composition brightening subtly at the center, ending on
> a stable, symmetrical, minimal frame. Macro cinematic, no text, no
> logos.

**SFX:** the same felted pluck from Scene 0, one octave up. Circle
closed.

---

# THE SKIP CUT (⎋ at any time)

*One card. The thread underlines the title, then sits still.*

> **"The short version."**
> Native macOS editor + terminal · your agents, orchestrated, gated ·
> no accounts, no telemetry, keys in Keychain · idles under 150 MB.

Four compact rows with the real controls inline: **Theme** (system-
matched picker) · **Agents** (live probe results, one line) · **AI +
usage** (key field + Later) · **`rafu` command** (Install / Later).
One primary button: **[Open something]**. Total: under 60 seconds,
zero shame, same honesty.

---

# THE SCORE (all sound optional)

One 100-second piece, structured to the scenes, mixed to −18 LUFS,
ending resolved (not faded) at the caret. Generation prompt for a music
model:

> Instrumental, 100 seconds, 68 BPM, in D. A quiet tanpura-like drone
> foundation with warm tape saturation; a solo santoor (or koto)
> playing sparse, deliberate plucked phrases that mimic a loom's
> shuttle — irregular but purposeful rhythm; a soft felt-piano enters at
> the midpoint with a rising four-note motif; subtle room tone and
> fabric-rustle foley woven low in the mix; builds gently to a single
> confident resolved chord at 1:34, then two seconds of near-silence,
> then one final soft plucked note. No percussion kit, no synth leads,
> no vocals. Mood: handmade, nocturnal, precise, quietly triumphant —
> a craftsman finishing something at 2am and smiling.

**SFX kit (generate or record):** felted string pluck ×3 pitches ·
wooden bobbin tick · cloth settle/whoosh · dye-ripple shimmer (soft,
almost subliminal) · the bow-tie (tiny, dry, comedic restraint).

---

# Copy bank (spares & alternates, same voice)

- "Seven agents walk into a repo. Rafu gives each its own worktree so
  the joke never ends in a merge conflict."
- "Gates, not vibes: nothing merges until a human reads the diff."
- "The notch knows when a gate is waiting. Your notch. Employed at last."
- "Dark mode detected. Condolences to your circadian rhythm; Indigo
  will look wonderful on it."
- "We don't have a cloud. We have your computer, which — fun fact — is
  also a computer."
- (Empty-agents alt) "Zero agents found. Independence is also a
  workflow."

---

# Technical notes (for the eventual implementation plan)

- **Structure:** a `FirstLaunchExperience` SwiftUI scene shown before
  the first `WorkspaceWindow` when `RafuFirstLaunchStore.completed ==
  false` (UserDefaults: `firstLaunchExperienceVersion: Int`, so a
  future v2 can re-invite, never auto-replay). Help menu adds "Play the
  Intro Again" (replays with all setup steps pre-filled/read-only).
- **Playback:** AVKit `AVPlayerLayer` for bundled H.265 videos; SwiftUI
  Canvas/Metal shader for the dye ripple and thread-underline strokes;
  vendor marks composited live from `agent-*.svg` (AT-01). No WKWebView
  anywhere — the intro obeys the product's own architecture rules.
- **Real work during theater:** Scene 4 runs `ConductorAdapterRegistry`
  probes (bounded, timeout 3 s each, parallel) — the animation is paced
  so probes finish inside it; results stream in as they land. Scene 5
  writes Keychain via the existing AI provider path. Scene 6 calls the
  existing `CLIInstaller`. The intro is a skin over real, already-shipped
  setup surfaces — it introduces no new capability code.
- **Accessibility:** every scene's copy IS the VoiceOver script, read in
  order; all interactions keyboard-first (⏎ advance, ⎋ skip, arrows
  between cards/swatches); Reduce Motion swaps every video for its still
  triptych with crossfades; Reduce Transparency and Increase Contrast
  honored; sound off by default and never required for meaning.
- **Performance honesty:** assets load lazily per scene and the whole
  experience is torn down after completion — the 150 MB idle budget is
  measured *after* the intro exits, and the intro itself must stay under
  a defined ceiling (decide in ADR).
- **Nothing transmits.** Probes are local. The intro makes zero network
  requests. (The AI [Test] button is the single exception, user-pressed,
  clearly labeled.)

# Asset manifest

| ID | Kind | Duration/Size | Grades | Generator |
|---|---|---|---|---|
| V0 | Knot loop + pull | 8 s + 1 s | Indigo, Khadi | /openrouter-video |
| V1 | Weaving the workbench | 14 s | Indigo, Khadi | /openrouter-video |
| V2 | Bobbins descend | 8 s | Indigo, Khadi | /openrouter-video |
| V3 | The resolve | 6 s | Indigo, Khadi | /openrouter-video |
| I1–I3 | Truth-card backdrops | 2560×1600 | Indigo, Khadi | /openrouter-images |
| M1 | Score | 100 s | one | music model (prompt above) |
| S1–S6 | SFX kit | <2 s each | one | generate/record |

Budget target: **≤ 25 MB added to the app** (H.265 at these durations
comfortably fits; the ADR sets the hard number). Every asset checked in
with provenance + prompt + SHA-256, same discipline as the icon set.

# Open decisions (the ADR this needs before any code)

1. Bundled-media ceiling (proposed ≤ 25 MB) and whether V-assets ship
   in-app or the intro degrades to the shader-only cut without them.
2. Music: ship it (score + SFX ≈ 2–3 MB) or SFX-only.
3. Shader-vs-video split (recommend: V0/V1/V2/V3 video, dye ripple and
   all thread-strokes shader).
4. Localization of witty copy (wit rarely survives translation —
   proposal: en only at first, straight copy elsewhere).
5. Whether the Ensemble scene appears when the Ensemble phases haven't
   shipped in the installed build (gate scenes on feature flags).

# Production workflow

1. Generate stills first (`/openrouter-images`) to lock the visual
   grade per cut; iterate until I1 matches the theme JSONs when sampled.
2. Feed the approved stills as reference frames into
   `/openrouter-video` for V0–V3 (both grades).
3. Generate M1 + SFX; mix to −18 LUFS.
4. Place under `Resources/Onboarding/{indigo,khadi}/`, record SHA-256 +
   prompts in `docs/references/onboarding-assets.md`.
5. Then — and only then — write the implementation plan doc with owned
   paths and a worktree prompt, same shape as the C8/AT plans.
