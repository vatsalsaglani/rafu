# Markdown local image resolution and provider quirks

- Applies to: Markdown preview/split rendering of `![]()` image references
  (`swift-markdown-ui` boundary)
- Last verified: Swift 6.2.4, macOS SDK 26.x, 2026-07-19

## Rule or observed behavior

- MarkdownUI's `ImageView` resolves a Markdown image `source` string against
  its configured `imageBaseURL` using `URL(string:relativeTo:)` *before*
  ever calling `ImageProvider.makeImage(url:)`. A `URL` built with
  `relativeTo:` retains the original `relativeString`/`baseURL` pair
  internally — two references that resolve to the same on-disk location
  (one written as relative, one as absolute) are **not** `==` to each other
  as raw `URL` values. `MarkdownImageReference.resolve(source:relativeTo:)`
  normalizes this away by taking `.absoluteURL` of the resolved URL before
  classifying it, so `local`/`remote`/`invalid` comparisons and tests are
  stable regardless of how the source was written.
- `DefaultImageProvider` (MarkdownUI's built-in provider) is **network-only**
  — it has no local-file decode path. `LocalFileImageProvider` intercepts
  only `file://` URLs (classified via `MarkdownImageReference.resolve`) and
  routes everything else (`http`/`https`, unresolved/invalid) to
  `DefaultImageProvider.default.makeImage(url:)` unchanged, so remote images
  keep loading exactly as before this change.
- Local image decode (`LocalMarkdownImageLoader`) runs off the main actor via
  a `@concurrent` static `load(url:)`, downsampled to a bounded
  `maxDecodedPixelSize` (2,560px) with
  `CGImageSourceCreateThumbnailAtIndex` — the same bound
  `ImagePreviewView.load` already used for the full-tab image preview — and
  SVG renders natively via `NSImage(contentsOf:)`. A decode failure shows a
  placeholder glyph, never the raw source path, so a missing/corrupt local
  image degrades quietly instead of breaking the render.

## Why it matters

Without the `.absoluteURL` normalization, `relativeTo:`-resolved and
plain-absolute references that point at the same file would classify or
compare inconsistently. Without routing non-local URLs back to
`DefaultImageProvider`, a custom `ImageProvider` would silently break remote
image loading (MarkdownUI's default network path) the moment it was
installed, since a custom provider fully replaces the default rather than
composing with it.

## Reproduction or evidence

Markdown documents with a relative image path (`![](./assets/img.png)`), an
absolute local path (`![](file:///Users/.../img.png)`), and a remote image
(`![](https://example.com/img.png)`) opened in Markdown split/preview mode;
the relative and absolute local references resolve to the same
`MarkdownImageReference.local`, and the remote reference still loads through
`DefaultImageProvider`.

## Verification

```bash
swift build
swift test
./script/build_and_run.sh --stage
```

## Related code, ADRs, and phases

- `Sources/RafuApp/Markdown/MarkdownImageProvider.swift`
- `Sources/RafuApp/Views/ImagePreviewView.swift`
- [`editor-dependencies.md`](editor-dependencies.md) (`swift-markdown-ui` pin)
- `docs/plans/phases/pre-initial-push-workbench.md`
