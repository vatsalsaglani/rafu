/**
 * Prefixes a `public/`-rooted path (e.g. "/media/hero-loop.mp4") with the
 * app's deploy base — "/" locally, "/rafu/" on GitHub Pages today. Vite
 * only rewrites asset URLs it can see at build time (import()'d assets, or
 * attributes inside index.html); a plain string literal used as a `src` in
 * a component is resolved by the BROWSER at runtime against the page's
 * origin, so on a sub-path deploy "/media/x.mp4" 404s (it asks the domain
 * root, not /rafu/media/x.mp4) unless it's run through this first. Every
 * public/ asset referenced from component code must go through `asset()`.
 */
export function asset(path: string): string {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "");
  return `${base}${path}`;
}

export const GITHUB_URL = "https://github.com/vatsalsaglani/rafu";
export const GITHUB_RELEASES_URL = `${GITHUB_URL}/releases`;

/** Bump with each published release; shown in the post-download install dialog. */
export const LATEST_RELEASE = {
  version: "v0.1.2-beta",
  asset: "Rafu-v0.1.2-beta-macos-arm64.zip",
} as const;

export const NAV_SECTIONS = [
  { label: "Craft", href: "/#craft" },
  { label: "Features", href: "/#features" },
  { label: "Themes", href: "/#themes" },
] as const;
