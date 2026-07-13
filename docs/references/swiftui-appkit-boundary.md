# SwiftUI and AppKit boundary

- **Applies to:** scenes, per-window state, native commands, and the TextKit editor
- **Last verified:** Swift 6.2.4, Xcode 26.3, macOS 26.1 on 2026-07-13

## Ownership rule

Use SwiftUI to own scenes and small UI-visible metadata. Each `WindowGroup` instance creates one `WorkspaceSession`; do not place window selection, tabs, drafts, or connection errors in a global singleton.

Use AppKit only for capabilities that genuinely require it. The editor boundary is an `NSViewRepresentable` around `NSTextView`/TextKit. SwiftUI passes stable configuration and metadata into the bridge; the text system owns the mutable document storage and high-frequency selection/editing behavior. Open tab views remain mounted while hidden so tab selection cannot destroy an unsaved buffer.

## Non-negotiable buffer rule

The full live document string never becomes an `@Observable`, `@State`, `@Binding`, environment, or view property that changes on every keystroke. Observable metadata may include file identity, revision, dirty state, encoding, line endings, and lightweight selection/status values.

## Scene and control rule

- Primary workspaces use `WindowGroup`; settings use a dedicated `Settings` scene.
- Keep the sidebar native and selection-driven with stable IDs.
- Add repeatable actions to commands/menus and expose important ones visibly in content or toolbar.
- Prefer native materials and system-adaptive chrome. Apply Indigo/Khadi to content/editor semantics, not as opaque paint over every native pane.
- Use AppKit panels, responder-chain hooks, or lower-level window control only after SwiftUI's scene/control APIs prove insufficient.

## Editor checkpoint

The pre-first-commit checkpoint uses a focused bespoke bridge with native undo/find and debounced syntax attributes. Future Phase 0/2 work must still evaluate IME and Unicode behavior, line numbers, larger-file performance, and whether a specialized editor component earns its dependency cost without breaking the no-full-text-observation rule.

## Editor decorations must not live in text storage

The Neon syntax pipeline periodically calls `setAttributes` over the full `NSTextStorage` range (`SyntaxHighlighter.applyBaseStyle`), so any decoration written as a storage attribute is silently clobbered. Verified decoration layers that survive re-highlighting:

- Current-line highlight, indent guides, and matched-bracket boxes draw in `RafuTextView.drawBackground(in:)`.
- Line numbers and Git change strips draw in `EditorGutterRulerView` (an `NSRulerView`); its per-buffer line-start index is invalidated in `textStorage(_:didProcessEditing:...)` and rebuilt lazily on the next draw.
- Find-match highlights use `NSLayoutManager` temporary attributes, gated on `DocumentFindState.isActive` because `refresh()` also runs on every keystroke while the find bar is closed, and capped at 2 000 painted matches.

Two supporting nuances:

- `NSTextView(frame:)` can create a TextKit 2 view that silently converts to TextKit 1 when `layoutManager` is touched. `RafuTextView.makeTextKit1()` builds the `NSTextStorage → NSLayoutManager → NSTextContainer` stack explicitly so gutter and background drawing are deterministic.
- Editing behaviors (⌘/ toggle comment, auto-indent on Return) must run through `shouldChangeText`/`replaceCharacters`/`didChangeText` (or `insertText(_:replacementRange:)`) so undo and the Neon `didProcessEditing` path both observe a normal edit.

## File importer result shape

SwiftUI's `fileImporter` overload that includes `allowsMultipleSelection:` returns `Result<[URL], Error>` even when the argument is `false`. Select the first URL explicitly and handle an empty success defensively. URLs returned by the importer may be security-scoped; acquire the new scope before releasing the current workspace, keep access for exactly the workspace lifetime, and balance a successful `startAccessingSecurityScopedResource()` with `stopAccessingSecurityScopedResource()`.

Evidence: the initial Xcode 26.3 build rejected treating the success value as a single `URL`; `WorkspaceWindowView` and `WorkspaceSession` contain the verified handling.

See Apple's [`startAccessingSecurityScopedResource()` documentation](https://developer.apple.com/documentation/foundation/url/startaccessingsecurityscopedresource()).

## Verification

- Open two workspace windows and confirm independent session state.
- Confirm Settings uses its own scene.
- Confirm every important action has keyboard/menu reachability.
- When the editor exists, trace typing without SwiftUI-wide invalidations or full-string copies.

## Related material

- Product plan §§4, 6, 7, and 15
- `Sources/RafuApp/`
- Phase 0 and Phase 1A plans

## NSRulerView draws unclipped on macOS 14+

- Applies to: `EditorGutterRulerView` and any future custom `NSView.draw`
  override that fills its dirty rect.
- Last verified: macOS 15 SDK, 2026-07-13.
- Rule: `NSView.clipsToBounds` defaults to **false** since macOS 14, and
  AppKit passes ruler views a dirty rect wider than their bounds. An
  unclipped `dirtyRect.fill()` therefore paints over the entire editor
  content (glyphs, tab bar, breadcrumbs render invisible while line numbers
  drawn afterwards survive). Set `clipsToBounds = true` in the view's init,
  or fill `bounds.intersection(dirtyRect)`.
- Evidence: offscreen bitmap probe rendered ~52 non-background pixels with
  the unclipped gutter vs ~1,314 after the fix; regression covered by
  `Tests/RafuAppTests/EditorGutterRenderTests.swift`.
- Related: hand-built TextKit 1 stacks must also retain their
  `NSTextStorage` (`NSLayoutManager.textStorage` is an `assign` reference;
  the view only retains its container) — `RafuTextView.ownedTextStorage`.
