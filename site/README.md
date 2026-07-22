# rafu-land-doc

The landing page and documentation site for **Rafu** — the native macOS repository
companion. One Vite + React app serving both.

- **Plan:** [`PLAN.md`](PLAN.md) — brand system, information architecture, full copy
  deck, motion rules, and build order. Read it before changing anything.
- **Product source of truth:** the Rafu repository beside this folder
  (`../rafu`) — its `README.md`, `docs/plans/rafu_product_architecture_plan.md`,
  ADRs, and bundled themes (`indigo.json`, `khadi.json`).

## Commands

```bash
npm install
npm run dev       # local dev
npm run build     # typecheck + production build → dist/
npm run preview   # serve the production build
```

Requires Node.js 22.12+ (22.0 works with a warning).

## How it fits together

| Area | Where | Notes |
|---|---|---|
| Design tokens | `src/styles/main.css` | Indigo (dark) / Khadi (light) lifted from the app's theme JSON; flip via `[data-theme]` |
| Logo & samples | `src/brand/` | The seam mark (theme-adaptive), code samples, OG master SVG |
| Generated media | `public/media/`, `media-src/` | AI-generated cloth photography + 6s hero loop (OpenRouter: Nano Banana Pro, GPT Image 2, Kling v3.0 Pro). Masters in `media-src/`; see PLAN.md §2.4.1 |
| Landing sections | `src/sections/` | Hero, Craft, Features, DeepDives, NonGoals, Themes, Numbers, Cta |
| Docs content | `src/docs/*.md` | 14 pages; frontmatter `title` / `description` / `badge` |
| Docs pipeline | `plugins/vite-rafu-docs.ts` | Markdown → `{ meta, toc, html, plainText }` at build time; `?highlight` imports for code samples |
| Code highlighting | `plugins/shiki-rafu-themes.ts` | Shiki TextMate themes converted from the app's own syntax tokens — the site renders Rafu's real colors |
| Docs registry | `src/lib/docs.ts` | Nav groups, page order, search index source |

## Editing docs

Add a markdown file to `src/docs/`, register its slug in `src/lib/docs.ts`
(`docsNav`), and it gets sidebar nav, TOC, search, and prev/next links automatically.
Code fences are highlighted at build time — no client-side highlighter.

## Deploy

Static files (`dist/`) — any static host works. SPA fallback (`/* → /index.html`) is
required for client routes. `public/og.png` is generated from
`src/brand/og-master.svg` (square master, center-crop to 1200×630).

## Honest placeholders (pre-launch)

- `Download for macOS` is an inert *soon* pill (`src/components/DownloadSoon.tsx`)
- `GITHUB_URL` in `src/lib/site.ts` points at the intended repository path — confirm
  after the first push
- Docs pages for later-release features (SSH workspaces, the CLI) carry badges saying so
