# Rafu web — landing + documentation plan

Site for **Rafu** (રફૂ), the native macOS repository companion. One React app that serves
both as the marketing landing page and the product documentation.

- **Stack:** Vite 7 + React 19 + TypeScript + Tailwind CSS v4 + react-router 7
- **Docs:** markdown files compiled at build time by a small Vite plugin; code highlighted
  with Shiki using themes converted from Rafu's own `indigo.json` / `khadi.json`
- **Theme:** Indigo dark-first, Khadi light toggle (mirrors the app's system-appearance behavior)
- **CTA:** "Download for macOS" placeholder + GitHub link (product is pre-distribution)

---

## 1. The story we are telling

Source: `docs/plans/rafu_product_architecture_plan.md` §2.4, `README.md`.

> **Rafu (રફૂ / रफ़ू)** — darning. The everyday Gujarati/Hindi/Urdu word for mending a
> small hole in otherwise good fabric. The *rafugar* is the craftsperson whose repairs
> are meant to be invisible.

The product's exact job description: **the coding agent weaves the cloth; Rafu is what
you reach for to mend the hole** — the `.env`, the Dockerfile, the manifest, the one
wrong line in a generated migration.

Positioning (never deviate from this):

- Rafu is a **repository companion**, not an IDE, not an agent host, not a platform.
- It exists for people who drive Codex / Claude Code / terminal agents and need a fast,
  native place to inspect, adjust, review, and commit.
- Its defining constraints are features: native interaction, predictable memory,
  explicit user control, deliberately narrow scope.

## 2. Brand system (from the app, not invented)

### 2.1 Logo — "the seam"

Two indigo cloth panels laced by a single zari-gold zigzag thread. It encodes the
product three ways: the mend (rafu), the split editor / side-by-side diff, and the
local↔SSH workspace pair joined by one seam.

- Source: `Resources/AppIcon/rafu-icon-seam.svg` (squircle version → favicon, og-image).
- Inline web mark: the two panels + gold stitch without the squircle, so it can sit on
  any background at any size. At tiny sizes the zigzag may relax to a straight gold seam.
- The રફૂ script glyph appears once, large, in the "what does Rafu mean" story card —
  per the plan, the script is reserved for places where it has room to breathe.

### 2.2 Color

Tokens lifted directly from `Resources/Themes/indigo.json` and `khadi.json`. The site
uses the same semantic names as the app (`bg`, `editor`, `elevated`, `border`,
`text`, `accent`…), mapped to CSS custom properties and swapped by a `data-theme`
attribute. Dark = Indigo, light = Khadi.

Key values (dark / light):

| Role | Indigo (dark) | Khadi (light) |
|---|---|---|
| Page background | `#10141C` | `#F1EDE3` |
| Surface / editor | `#151A24` | `#FAF7F0` |
| Elevated | `#1B212D` | `#FFFFFF` |
| Border subtle / strong | `#262E3E` / `#333D52` | `#E3DCCB` / `#CFC6B0` |
| Text primary / secondary / muted | `#E7EAF2` / `#9AA3B8` / `#67718A` | `#2B2F3A` / `#5D6474` / `#8A90A0` |
| Accent (zari gold) / hover | `#E3A857` / `#EDB96F` | `#A2701F` / `#8A5D14` |
| On-accent | `#201709` | `#FFF9EE` |
| Success / error / info | `#7CC08A` / `#E06C75` / `#82A7F0` | `#2E7D46` / `#B3362E` / `#3557B7` |
| Git added / modified / deleted | `#7CC08A` / `#D2B958` / `#E06C75` | `#2E7D46` / `#8F6A10` / `#B3362E` |
| Syntax: keyword / function / type | `#9D8CE8` / `#74BFCB` / `#82A7F0` | `#6C4FC4` / `#1E7A87` / `#3557B7` |
| Syntax: string / number / comment | `#9FC98F` / `#E0B36A` / `#5F6980` | `#4E7D45` / `#9A5F12` / `#8C8776` |

Rules: gold is reserved for meaning — primary actions, the seam motif, active states.
Never paint large backgrounds with it. Git states never encoded by color alone (labels
accompany).

### 2.3 Typography

| Role | Face | Why |
|---|---|---|
| UI / body | **Inter Variable** (opsz) | Neutral, native-feeling; stands in for the app's system font |
| Display accent | **Instrument Serif** italic | The craft/voice layer — a few words per headline, like the app's New York prose serif |
| Code | **JetBrains Mono** | The app's own editor-font fallback |

Type rules (from the apple-design skill): negative tracking as size grows
(`-0.02em`…`-0.04em` on display sizes), tight leading on headlines (`1.02`–`1.1`),
comfortable body leading (`1.6`), `rem`-based spacing, optical sizing on.

### 2.4 Motifs & texture

1. **The gold stitch** — a zigzag SVG path that draws itself across section dividers
   and behind the hero word. One path, drawn once, critically-damped. This is the site's
   signature.
2. **Halftone/dither** — the inspiration set (Castle, Miracle, Designpixil) uses
   dot-matrix imagery. We apply it abstractly: a fine dot-grid cloth texture at very low
   opacity on hero/CTA backgrounds, and dithered gradient panels — evoking woven cloth,
   never photos.
3. **Generated cloth photography** — AI-generated macro stills and one 6s ambient
   loop of indigo cloth / khadi cotton with a gold running stitch (see §2.4.1).
   Always masked, faded, and low-opacity; typography always wins.
4. **App windows** — product visuals are CSS-built mocks of the real Rafu window
   (sidebar, tabs, editor with true Indigo syntax colors, status bar), not screenshots.
   Durable, sharp at any density, and honest about a product still before its first push.

#### 2.4.1 Generated media (OpenRouter pipeline)

Generated 2026-07-18 with the repo's `openrouter-images` / `openrouter-video` skills;
raw masters in `media-src/`, optimized web assets in `public/media/`.

| Asset | Source | Model | Use |
|---|---|---|---|
| `hero-indigo.webp` | Nano Banana Pro (`google/gemini-3-pro-image`), 2K 16:9 | Indigo macro weave + gold stitch | Dark hero poster/fallback, CTA backdrop (dark) |
| `hero-khadi.webp` | same, 2K 16:9 | Khadi daylight cotton + antique-gold stitch | Light hero backdrop, CTA backdrop (light) |
| `craft-still.webp` | GPT Image 2 (`openai/gpt-image-2`), high | Zari spool on folded indigo | ~~Craft section visual~~ **Retired**: replaced by the CSS-built `MendDiff` mock so the section shows the product; master kept in `media-src/` |
| `hero-loop.mp4` + `hero-poster.webp` | Kling v3.0 Pro (`kwaivgi/kling-v3.0-pro`), 6s 720p 16:9, first_frame = last_frame = hero-indigo master | Ambient cloth loop | Dark hero background video |
| `hero-loop-khadi.mp4` | same, first_frame = last_frame = hero-khadi master | Ambient khadi loop, sun glint on thread | Light hero background video |

Video history: v1 (2026-07-18, $0.67) was near-static (0.60/255 frame delta over 3s — imperceptible
behind the hero overlays). Regenerated 2026-07-19 as v2 (job `9hIOBL0uD1mIH6tKVw1d`, $1.01) with a
motion-forward prompt (fabric sway, light traveling the gold thread): 3.15/255 frame delta, loop
seam 1.01/255, 515KB after re-encode (v1 was 865KB). Master: `media-src/hero-loop-v2.mp4`.
Khadi loop (2026-07-19, job `w4AM5pCtpT86BVUTQEQk`, $1.01): same prompt on the khadi master —
motion 10.11/255 (sun glint sweeping the thread), seam 1.67/255, 803KB. Master:
`media-src/hero-loop-khadi.mp4`. Both loops play in their theme; reduced motion gets the still.

Regeneration: prompts are in git history / this section's spirit — macro, plain-weave,
single diagonal running stitch, palette-locked (10141C/151A24/E3A857 dark,
F1EDE3/FAF7F0/A2701F light), generous negative space, no text or watermark.

Rules: each theme plays its own loop and pauses offscreen; reduced-motion users get the
poster frame; total media budget ≈ 1.2 MB; every image carries real alt text or is
explicitly decorative (`alt=""` + `aria-hidden`).

### 2.5 Voice

Calm, precise, confident; a little poetic about craft; never hypey. Short sentences.
No exclamation marks. No "supercharge", no "blazing fast", no emoji. Gujarati/Hindi
terms are used sparingly and always glossed. Numbers are stated as budgets, not promises
("budgeted below 150 MB", matching the plan's honesty).

## 3. Copy deck (v1 — all copy written here first)

**Hero**

- Eyebrow: `Rafu · રફૂ · a native macOS repository companion`
- H1: **The agent weaves. *You mend.***  ("You mend." in Instrument Serif italic, gold)
- Sub: `Rafu — રફૂ, "darning" — is a small, native editor for the focused fixes that remain after a terminal coding agent has done the larger weave. Open the repository. Fix the .env. Review the diff. Commit.`
- Primary CTA: `Download for macOS` (placeholder badge `soon`) · Secondary: `Read the docs` · Tertiary: GitHub
- Micro-trust line: `Free. Native. No account. macOS 15+.`

**Story card**

- `રફૂ` large, glossed: *(rah-foo) — darning.*
- Body: `The rafugar's craft is the repair you never notice. Your coding agent weaves the cloth — the feature, the refactor, the scaffold. Rafu is what you reach for to mend what's left: the .env value, the Dockerfile line, the manifest the agent almost got right.`

**Feature grid (6)**

1. **Truly native** — TextKit 2 editing, real windows, real menus, system appearance. No Electron, no WebView canvas.
2. **Git, at a glance** — Changes, history, branches, side-by-side diffs, hunks, stash, blame. Review what the agent did before you commit it.
3. **Explicit AI commit messages** — Drafted from a diff scope you choose, with secrets redacted and the exact payload previewed. Nothing is sent automatically. Nothing commits automatically.
4. **Markdown, rendered natively** — GFM with native Mermaid diagrams, split or preview per document. No per-document WebView.
5. **Themes as data** — JSON theme files, hot-reloaded on save. Indigo (dark) and Khadi (light) bundled; write your own.
6. **Small on purpose** — Idle memory budgeted below 150 MB. Syntax parsing for open buffers only. Zero persistent Git processes.

**Deep dives (3 alternating sections)**

1. **Made for the last mile of agent work** — multi-window workspaces, fast project search, quick open, an embedded terminal when you need one command, restoration that picks up where you left off.
2. **Review, then commit — on your terms** — the Git flow: changes → stage → draft message from an explicit scope → edit → commit. Trust prompts before hooks run; hook output shown.
3. **One window, local or remote** — SSH workspaces (in a later release) use your own `~/.ssh/config` through the system `ssh`. Same editor, same Git, same mental model.

**Non-goals (distinctive section)**

Headline: **Deliberately *not* an IDE.**
- No extension marketplace · No embedded coding agent · No AI chat · No debugger · No collaboration · No per-document WebViews · No silent network calls
- Closer: `Every feature must support opening, editing, reviewing, or committing a repository. If it doesn't, it isn't in Rafu.`

**Themes showcase** — the same code sample in Indigo and Khadi, switchable. Copy: `Two palettes, one identity. Indigo-dyed cloth at night; undyed khadi in daylight; one zari-gold thread through both.`

**Numbers / ethos strip**

- `< 150 MB` idle-memory budget · `1 frame` p95 typing target · `0` persistent Git processes · `0` automatic network calls

**Final CTA** — `Ready when you are.` + Download (soon) + docs + GitHub.

**Footer** — seam mark, small nav (Docs, Themes, GitHub), line: `Rafu — a mending tool for the agent era.` + © line.

## 4. Site architecture

### Routes

```
/                     landing (single page, anchored sections)
/docs                 redirects to /docs/getting-started
/docs/:slug           documentation pages
*                     404
```

Landing sections (in order): nav · hero · story · feature grid · deep dive ×3 ·
non-goals · themes · numbers · CTA · footer.

### Docs information architecture (14 pages)

| Slug | Title | Source of truth |
|---|---|---|
| getting-started | Getting started | README, build-and-run.md |
| workspaces | Workspaces | plan §6, phase-1a |
| the-editor | The editor | plan §7, editor references |
| search | Find & replace | editor-search-and-restoration.md |
| markdown | Markdown & Mermaid | plan §7.7, ADR 0008 |
| git | Git in Rafu | plan §11, ADR 0011, phase-3 |
| commit-messages | AI commit messages | plan §12, phase-4 |
| themes | Themes | plan §4.5–4.6, indigo/khadi.json |
| cli | The `rafu` command | plan §9, ADR 0007/0009 |
| terminal | The terminal | ADR 0004 |
| language-intelligence | Language intelligence | ADR 0005, language-intelligence.md |
| shortcuts | Keyboard shortcuts | plan §4, workbench phase |
| privacy-and-security | Privacy & security | plan §13, SECURITY.md |
| roadmap | Roadmap | phases README, open-decisions |

Docs chrome: left sidebar (grouped: Start / Using Rafu / Reference), right "On this
page" TOC, prev/next pager, client-side search (⌘K, fuse.js over a build-time index),
theme toggle, "mark as later release" badges where the phase plan says so (SSH, CLI
install, signing).

## 5. Technical design

```
rafu-land-doc/
├── PLAN.md                      ← this file
├── index.html                   ← theme-bootstrap inline script (no flash), meta/OG
├── vite.config.ts               ← + markdown docs plugin
├── src/
│   ├── main.tsx / App.tsx       ← router, theme provider
│   ├── styles/main.css          ← Tailwind v4 @theme tokens from Indigo/Khadi
│   ├── brand/                   ← seam logo SVGs, dither texture, tokens
│   ├── components/              ← Nav, Footer, Button, AppWindow mock, SeamStitch,
│   │                              FeatureCard, ThemeToggle, Reveal (scroll)
│   ├── sections/                ← Hero, Story, Features, DeepDives, NonGoals,
│   │                              Themes, Numbers, Cta
│   ├── pages/                   ← Landing, DocsLayout, DocsPage, NotFound
│   ├── docs/                    ← the 14 markdown files (+ frontmatter)
│   └── lib/                     ← docs registry, search index, shiki theme JSON
└── public/                      ← favicon.svg (squircle seam), og.png
```

**Markdown pipeline:** a Vite plugin (`*.md` → JS module) that parses frontmatter
(gray-matter), highlights fenced code with Shiki at build time using Rafu Indigo/Khadi
TextMate themes (converted once from the app's JSON), extracts the heading TOC, and
emits `{ html, toc, meta }`. Zero markdown cost in the client; instant page switches.

**Code samples on the landing page** use the same Shiki output — the site literally
renders Rafu's syntax colors.

**Motion (apple-design rules):** springs, critically damped (`bounce: 0`,
`duration ≈ 0.3–0.4s`) via `motion`; pointer-down press feedback (`scale: 0.97`,
100 ms); scroll reveals = 10 px rise + fade, once; the seam stitch draws on
first view; translucent nav (`backdrop-filter`) with a scroll-edge fade instead of a
hard border; `prefers-reduced-motion` → cross-fades only, stitch pre-drawn; theme
switch transitions colors, never layout.

**Accessibility:** semantic landmarks, focus-visible rings in gold, AA contrast from
the app's own token table, full keyboard operability (⌘K search, `/` focus), no
color-only meaning.

## 6. Build order

1. Plan (this file) → scaffold + deps
2. Tokens, theme provider, fonts, logo/favicon
3. Landing: all sections + copy
4. Docs system: plugin, Shiki themes, layout, search, pager
5. Docs content: 14 pages from the sources above
6. Polish: motion pass, reduced-motion, responsive, meta/OG
7. Verify: `npm run build` clean + dev-server smoke test

**Out of scope (v1):** real download hosting, OG image generation pipeline, blog,
search server, analytics, i18n.
