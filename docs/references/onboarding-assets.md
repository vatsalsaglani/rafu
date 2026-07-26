# Onboarding asset generation and grading

**Applies to:** `Resources/Onboarding/{indigo,khadi}/*.jpg`, the seven base
stills (V0–V3, I1–I3) referenced by [`../plans/phases/first-launch-onboarding.md`](../plans/phases/first-launch-onboarding.md) ("The Unfolding").
**Last verified:** 2026-07-27, Higgsfield CLI 1.1.19, Pillow 12.3.0 (isolated
venv, not a repo dependency).

## What's here

Seven compositions × two grades (Indigo/Khadi) = 14 JPEGs, 2560×1440,
~6.7 MB total:

| File | Scene | Notes |
|---|---|---|
| `V0-knot.jpg` | 0 — cold open | knot + trailing thread |
| `V1-loom.jpg` | 1 — title weave | flat top-down; forms the workbench layout (sidebar / ruled editor / status strip) purely from thread geometry |
| `V2-bobbins.jpg` | 4 — agent discovery | seven wound spools, lit from within (dim = not installed, lit = found) |
| `V3-resolve.jpg` | 7 — the caret | same rectangle as V1, ruled lines resolved to a single upright caret — cross-dissolves cleanly from V1 |
| `I1-native.jpg` / `I2-private.jpg` / `I3-quiet.jpg` | 2 — truth cards | low-contrast text backdrops |

## Generation

- **Model:** `gpt_image_2` via the Higgsfield CLI (`higgsfield generate
  create gpt_image_2 --aspect-ratio 16:9 --resolution 2k --wait`).
  Higgsfield's own `--wait` blocks until the job completes and returns
  `result_url`; the file is fetched with a plain `curl`.
- **Auth:** `higgsfield auth login` (interactive), then `higgsfield
  workspace set <id>` — the CLI does not auto-select a workspace even
  with exactly one available; `account status` errors `No workspace
  selected` until you do.
- **Cost:** 7 credits/image on the PRO plan (600 credits/mo, $29) — 98
  credits for the full 14-shot set, ≈$0.34/image at PRO's rate.
- **Output:** 2688×1520 (native 2K) prior to grading/resize.

### Prompt rules (do not reintroduce these failures)

Diagnosed empirically across three generation passes (Seedream 4.5 →
OpenRouter GPT Image 2 → Higgsfield GPT Image 2). All three image models
share these failure modes:

1. **Never put a hex code in the prompt.** The model renders it as literal
   on-image text, plus invents catalogue labels and fake watermarks.
   Describe colour in words only ("warm honey-gold silk thread"), never
   `#E3A857`.
2. **Never use interface vocabulary** ("application window", "sidebar",
   "editor"). It produces a drawn white UI rectangle instead of physical
   thread. Describe geometry as thread paths: "the thread forms one
   straight vertical division near the left side."
3. **Never name a light fixture** ("lantern-lit"). It spawns a literal
   lantern in frame. Describe light behaviour, not fixtures.
4. **Use flat top-down framing for any shot needing legible layout** —
   "perfectly flat top-down overhead photograph, camera exactly parallel
   to the surface, no perspective distortion." A perspective shot of V1
   read as "a loom," not "the workbench." Flat framing fixed it, and as
   a side effect locked V1 and V3 to the same rectangle geometry, which
   is why they cross-dissolve cleanly.
5. **Khadi thread needs an explicit "fine thin"** in front of the thread
   description, or it renders visibly heavier/ropier than the Indigo
   grade's silk — a mismatch if the grades ever appear side by side.

Full prompt text for all 14 shots lives in the generation script history;
the canonical source is this file's per-shot table plus the scene
descriptions in `first-launch-onboarding.md`.

## Grading

Native output did not match brand hex values:

| | Generated (this pass) | Brand target |
|---|---|---|
| Indigo cloth | ~`#050610` (crushed near-black) | `#10141C` |
| Khadi cloth | ~`#CFBEA2` (warm tan) | `#F1EDE3` (cool ivory) |
| Thread (both grades) | close to target | — |

Two grading approaches were tried and rejected before landing on the one
used:

1. **Flat per-channel linear levels stretch** (black-point → target,
   white-point unchanged). Fixed Indigo. On Khadi it also reshaped
   midtones, desaturating the ochre thread toward pale cream — the
   thread's low blue channel got stretched as if it were a shadow, even
   though the pixel's overall luminance was high.
2. **Luminance-masked additive shift** (weight fades out as pixels get
   brighter). Correct idea for Indigo (cloth is dark, thread is bright)
   but wrong for Khadi: Khadi cloth is already near-white, so a
   brightness-weighted shift collapses to ~0 everywhere and the warm
   cast never gets corrected.

**What actually works:** mask by **chroma** (max−min channel), not
luminance — cloth is desaturated regardless of how light or dark it is;
thread is saturated. Blend each pixel toward the flat target color
proportional to `1 - chroma/90` (clipped, `**1.5` falloff, capped at 0.7
strength), using an **alpha blend toward the target** (`new = old +
(target - old) * weight`) rather than a fixed additive offset — a fixed
offset overshot on any shot whose cloth started brighter than the
grade's average (Khadi `V0-knot`'s near-white background blew out past
pure white). The alpha-blend form can't overshoot: the result is always
between the original value and the target.

Grading script: `apply_cloth_shift()`, run once per grade over all seven
shots, using PRO's Pillow/numpy in an isolated venv
(`python3 -m venv` + `pip install pillow numpy` — never `pip install
--user` into system Python; Homebrew Python blocks that with PEP 668).

## Format and size

Graded output was resized 2688×1520 → 2560×1440 and saved lossless PNG:
**57 MB for 14 files** — too large for a bundled resource next to video
and audio still to come. Re-encoded as JPEG quality 90: **6.7 MB total**,
visually clean under inspection (thin high-contrast thread lines against
dark cloth show no ringing or blocking at 100%). JPEG is the right choice
here — these are photographic-grain stills with no transparency need,
not the icon/vector case that would call for PNG or SVG.

## Provenance / integrity

SHA-256 of each promoted file, computed at promotion time:

```
675fe0a5c50efea5ac6cf171ef3a66e1f4775829e5abb251e1880e6075e50acd  indigo/I1-native.jpg
a23d01281f5cd0c803d3e1066adbc5b010d5b30281865323524cf1500cc0a514  indigo/I2-private.jpg
bebb4484fe9eecc3dfd77f15a087d56198ae214c9d406b103ce3ea8cf158d9b1  indigo/I3-quiet.jpg
ec8395b05ab96fa54b3d225de59a1e9bff2c8804d2ef0e98d0ba1f1f56e50990  indigo/V0-knot.jpg
f5680edbe35c6e0ad1267743fa09f155537b09edd8c679f3b391fa2e9cf7a0d3  indigo/V1-loom.jpg
9e3bb5ccaedd90b01f51c73ca433e7b6a1d05d8afd7069d4c2410d1655e1c3e4  indigo/V2-bobbins.jpg
9604851ae18db70816271cf99089aad8433af5694c3fb07fa7282b6c21574d0d  indigo/V3-resolve.jpg
f01cc79d05b03ddfcc6d0944f0147fead6295b5c02f437b2b4545f92c6154d76  khadi/I1-native.jpg
f49eb07ce716024a8cffab7ce7fc2899fe8ba3039a5b4f2e42d563bd3eff5362  khadi/I2-private.jpg
e9049e858166c2929d109a4f5715208f1c2dc57ccf895fcecccd94f6ccc89f41  khadi/I3-quiet.jpg
69b341ecc9692651a5a5c4211551804734d7d53f1bd637749f819ffcd5408029  khadi/V0-knot.jpg
490ecd447ea61c4ee23494712092a1797063ece68dc91300233836d7af527d81  khadi/V1-loom.jpg
d490556c80f4fefcb07a9214212f8255b2e9717f10782fb8db2b9c9d44801e97  khadi/V2-bobbins.jpg
a06a230092cbd5f7d22d1f87e09974f4120b06772bb12c916a3a27874e8eb7e9  khadi/V3-resolve.jpg
```

## Video

Eight clips (V0/V1/V2/V3 × Indigo/Khadi), promoted to
`Resources/Onboarding/{grade}/*.mp4`:

- **Model:** `seedance_2_0` via Higgsfield CLI, image-to-video from the
  graded stills above as `--start-image`.
- **Settings:** `--aspect-ratio 16:9 --resolution 1080p --duration 5
  --generate-audio false --mode std`. Audio generation deliberately
  disabled — music/SFX are a separate, designed pass (see the
  screenplay's Score section), not something the video model should
  auto-generate.
- **Output:** 1920×1080, 24fps, ~5.04s, silent, 41 MB total (8 clips).
- **Cost:** 45 credits/clip on PRO — 360 credits for the original 8, plus
  90 more for one re-generation (see below). 600-credit monthly grant,
  52 remaining after this pass.

### V3-resolve required a prompt fix — do not regress this

First attempt described the ending as "the ruled lines retract, leaving
only the outer rectangle" — the model retracted the **outer border
too**, in both grades, leaving only the pulsing caret with no frame. This
breaks the intended exact match to the promoted `V3-resolve.jpg` still
(scripted as a match-cut / freeze-frame target). Confirmed by extracting
the true last frame (`ffmpeg -sseof -0.15 ... -frames:v 1`), not a
mid-pulse dim phase.

Fix: state the constraint about what must **stay the same** as
explicitly and separately from what changes: *"The outer rectangle
border stays perfectly intact, fully visible, and completely unchanged
in brightness and position for the entire clip — it must never fade,
dim, or disappear. Only the interior horizontal ruled lines slowly
retract..."* Splitting "this stays fixed" from "this changes" into two
separate sentences was what made the difference — the original single
sentence ("lines retract, leaving only X") let the model treat the whole
frame as transitional.

## Known open issue: media budget

`Resources/Onboarding/` is now **47 MB** (6.7 MB stills + 41 MB video) —
video alone puts the manifest at roughly double the screenplay's
own `≤25MB` target (`first-launch-onboarding.md`'s asset manifest
section). This is not a rounding error: 1080p/5s clips are inherently
4–7 MB each at this bitrate, and there are 8 of them. Options if this
needs to come down: lower resolution/duration, drop `bitrate_mode` to
match `standard` more aggressively (already default), cut the number of
grades bundled (ship one, generate/download the other on first launch),
or accept the larger footprint and revise the budget line in the ADR.
Not resolved here — flagging it is the requirement, not solving it
unilaterally, since the ceiling itself was never ratified as a hard
constraint (see "Open decisions" in the screenplay doc).

## Related / next

- Music/SFX generation and the onboarding ADR (media-budget ceiling —
  see above, whether to ship music, localization of copy, feature-flag
  gating on the Ensemble discovery scene) remain open per
  `first-launch-onboarding.md`'s "Open decisions" section.
- SHA-256 for the eight video files:

```
1ff9dc421887d3ccf9c7e9de1179e6ee41cecb5be2ccb84e26cef5a06d942311  indigo/V0-knot.mp4
b1e7e634d6c071fecf4f0cfa68af8b251c6bb284de0165e3255d5b86f9975a7f  indigo/V1-loom.mp4
ba3da1fcd25c42cfd297f724246ed0dbe7a7e8a1c4f19128f086ffb55ee7f5ca  indigo/V2-bobbins.mp4
dbe3374c2d76ddaea77f00c6c0e2b740a479cddecc0b58a355daff12227d2fad  indigo/V3-resolve.mp4
d5082e2c90e73dd87b3b25a9991b4ee456ffd633655dc337c193c2f8fdf8fc22  khadi/V0-knot.mp4
4898ecc1d57c323825b5afa29ff1f60771bfde6e6c1bbf91b4e2376a4a7da6cc  khadi/V1-loom.mp4
e8c55e8515360a6860706fd1451e388ce9eda4cbf06fd08c5325daf7e9e22854  khadi/V2-bobbins.mp4
8e0f6c9e6f61ae17e1ebda49b3381a9a662ade4f2a43f8227d241db2608c38b3  khadi/V3-resolve.mp4
```
