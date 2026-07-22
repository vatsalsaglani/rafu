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
