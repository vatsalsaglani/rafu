# Agent Terminal icon assets

## Applies to

This note covers the seven `Resources/FileIcons/agent-*.svg` vendor marks and
the `ConductorCLIIcons` catalog used by Agent Terminal identity surfaces. The
existing `claude.svg`, `codex.svg`, and `gemini.svg` file-tree assets are a
separate catalog and are deliberately out of scope.

## Last verified

- 2026-07-26
- `@lobehub/icons-static-svg` 1.94.0
- npm tarball integrity:
  `sha512-Inx1TYkjLH6YeHOIHeVW9+OM/xxRnk8TmcQVKquFUDBmE3X9sUuRGt7kALrrDBNNAbrWz7Qq6fAiFj9E9Mmw9Q==`
- Apple Swift 6.3.3 on macOS 26.5.2 (25F84), arm64

## Provenance and committed checksums

The package is published by the
[`lobehub/lobe-icons`](https://github.com/lobehub/lobe-icons) project. Each
source file came from
`https://unpkg.com/@lobehub/icons-static-svg@1.94.0/icons/<slug>.svg`.

| `ConductorCLIID` | Source slug | Vendored filename | Committed SHA-256 |
|---|---|---|---|
| `claudeCode` | `claude` | `agent-claude-code.svg` | `0ac9f74817666e66ca23a6e30b9738374f442ac589917f95dd98d51763ec213b` |
| `codex` | `codex` | `agent-codex.svg` | `cd3e7994c885868cb6fbccc685d5faf666e24e07d59bd5e9a940fb71e9570b76` |
| `openCode` | `opencode` | `agent-opencode.svg` | `ebfb6fa62d13adadcb7b870a13cff01952b9ab9c3f4c40ce1ea7e7adda0cb7c0` |
| `cline` | `cline` | `agent-cline.svg` | `c5773fd2d3f5302c0237df15e1c38a7cd7dcddbbe0b1550eed964356686743e6` |
| `kimi` | `kimi` | `agent-kimi.svg` | `ec134c64f7e70b931128c85ccc05afee1bd2cd0549b2fad2c97cc6ae24c8db70` |
| `geminiCLI` | `gemini` | `agent-gemini.svg` | `7bcfe61adbb20478548f27949a4294f006cd97b1a23e207ae62793ecc38b5d80` |
| `cursor` | `cursor` | `agent-cursor.svg` | `6fa750417439491bb76ef6a781f479e17d513311bf2c1f6f5d9e0d091f3ca18a` |

The three read-only file-tree assets had these hashes before and after AT-01:

| Filename | SHA-256 |
|---|---|
| `claude.svg` | `76f284df8f840fa41d202c5bc94de60f69f34e8b4bd2c4b0c99527d738a3003b` |
| `codex.svg` | `54897ba150a45d473496bd141b1dcb3b3ac74b7dac2ddfab8b41ad0e6fba8315` |
| `gemini.svg` | `1b0ff9d938ee8df5c761c088eba9e38b9a631e0f73fa025cd9c9acfb737c3545` |

## Normalization rule

The vendored files preserve the upstream `viewBox="0 0 24 24"`,
`fill="currentColor"`, geometry, and `width`/`height` values. Normalization
removes only the web-only `style="flex:none;line-height:1"` attribute and the
embedded `<title>`. Rafu supplies contextual accessibility labels and renders
the SVG as a monochrome template image. Do not redraw, simplify, recolor, or
combine the marks.

`ConductorCLIIcons.icon(for:)` is an exhaustive switch over
`ConductorCLIID`. Every entry retains the `terminal` system symbol and
secondary tint as a fallback, so a missing or rejected asset degrades without
hiding the provider's text identity.

## Exact refresh procedure

Run from the repository root. Review the resulting geometry diff and update
this note's version, tarball integrity, and checksums in the same change.

```bash
version=1.94.0
base_url="https://unpkg.com/@lobehub/icons-static-svg@${version}/icons"

for mapping in \
  "claude agent-claude-code" \
  "codex agent-codex" \
  "opencode agent-opencode" \
  "cline agent-cline" \
  "kimi agent-kimi" \
  "gemini agent-gemini" \
  "cursor agent-cursor"
do
  set -- $mapping
  slug="$1"
  filename="$2"
  curl --fail --location --silent --show-error \
    "${base_url}/${slug}.svg" \
    --output "Resources/FileIcons/${filename}.svg"
  sed -i '' -E \
    's/ style="[^"]*"//; s#<title>[^<]*</title>##g' \
    "Resources/FileIcons/${filename}.svg"
done

xmllint --noout Resources/FileIcons/agent-*.svg
shasum -a 256 Resources/FileIcons/agent-*.svg
```

Then run:

```bash
swift test --filter FileIconAssets
./script/format.sh --lint
```

The asset test also checks loadability as `NSImage`, template mapping,
`fill="currentColor"`, absence of `<title>` and `style`, and byte identity of
the three legacy file-tree assets. App-bundle staging asserts cover all seven
files in `script/build_and_run.sh`; AT-01 itself remains headless and does not
invoke that script.

## Licensing and trademark posture

`@lobehub/icons-static-svg` is MIT licensed, Copyright (c) 2023 LobeHub. That
license permits redistribution of the files; it contains no trademark clause
and does not decide rights in the depicted vendor marks. The marks remain
their owners' property.

Rafu uses each mark nominatively and only to identify that vendor's CLI. The
marks may be scaled and monochrome-tinted as template images, but must not be
redrawn, used as Rafu branding, or presented as an endorsement or partnership.
If a vendor objects, remove its asset and rely on the catalog's system-symbol
fallback.

## Why the `agent-` prefix exists

The flat FileIcons bundle already contains unrelated file-tree marks for
Claude, Codex, and Gemini. Those files come from different sources and use
different color and geometry conventions. Reusing or changing them would
couple Agent Terminal identity to file-name decoration and risk unrelated
regressions. The `agent-` namespace gives the uniform seven-provider catalog
clear ownership without changing the loader.

Unifying file-tree vendor icons with this catalog is a possible future
follow-up. It requires its own visual and regression review and is explicitly
out of scope for AT-01.

## Related

- [ADR 0021](../decisions/0021-agent-terminals.md)
- [AT-01 phase](../plans/phases/conductor/AT-01-agent-terminal-sessions.md)
- [Agent Terminal launch contract](agent-terminals.md)
