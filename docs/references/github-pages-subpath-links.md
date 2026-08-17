# GitHub Pages subpath links

- **Applies to:** Internal navigation in `site/` when GitHub Pages serves the
  site below `/rafu/`
- **Last verified:** Vite 7.0.5, React Router 7.6.3, and GitHub Pages on
  2026-08-17

## Rule or observed behavior

A plain browser link that starts with `/` resolves from the domain root. On the
Rafu project site, `href="/#features"` therefore opens
`vatsalsaglani.github.io/#features` and drops the required `/rafu/` path.

Use React Router `Link` for internal links in React components. The configured
`BrowserRouter` basename then adds the Vite public base. Markdown is rendered to
plain HTML, so the Rafu docs plugin must add Vite's resolved `config.base` to
root-relative Markdown links during the build. Fragment-only links such as
`#installation` stay relative to the current page. External and protocol links
must stay unchanged.

## Why it matters

GitHub Pages project sites do not deploy at the origin root. A root-relative
anchor can appear correct during a root-based local preview but leave the
project site after deployment. The same fault can affect landing-page section
links and cross-page links compiled from Markdown.

## Reproduction or evidence

1. Build the site with `SITE_BASE=/rafu/`.
2. Open `/rafu/` in the production preview.
3. Follow a plain `href="/#features"` link.
4. The browser requests `/#features` instead of `/rafu/#features`.
5. A React Router `Link` produces `/rafu/#features`. The docs plugin produces
   `/rafu/docs/...` for a Markdown link written as `/docs/...`.

## Verification

```bash
cd site
SITE_BASE=/rafu/ npm run build
npm run preview -- --host 127.0.0.1
```

From `/rafu/`, use the Craft, Features, Themes, and Docs links. From a docs
page, use a cross-page Markdown link and a heading link. Every internal URL must
retain `/rafu/`; heading links must retain the current document path.

## Related code and deployment

- `site/src/main.tsx`
- `site/src/components/Nav.tsx`
- `site/src/components/Footer.tsx`
- `site/plugins/vite-rafu-docs.ts`
- `site/vite.config.ts`
- `.github/workflows/deploy-site.yml`
