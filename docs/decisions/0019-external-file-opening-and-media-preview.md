# ADR 0019: External file opening and media preview boundaries

- **Status:** Proposed
- **Date:** 2026-07-24

## Context

Rafu's initial scope was to edit files within a workspace; opening files outside the workspace was not explicitly addressed in the original product plan or acceptance contract. During the pre-initial-push-workbench polish phase, the user requested support for opening arbitrary external files (outside workspace root) via Finder drag-and-drop, with special handling for media files (images, video) to preview them inline rather than open them as text.

This is a new capability that touches the file-identity model, persistence, and the editor's media-rendering boundary. It requires a durable decision because:

1. **Workspace identity:** Rafu explicitly preserves workspace identity separate from remote paths and local files (per AGENTS.md's architecture invariants). External files outside the workspace root are a new class of identity.
2. **Media preview:** introducing media rendering (via `ImagePreviewView` for bitmaps/SVG, new `VideoPreviewView` for video) extends the editor's output model and adds a new class of view types.
3. **Atomicity and persistence:** external files are edited in-place (atomic writes to their original on-disk paths, never inside the workspace), which is different from workspace-internal files.

## Decision

### External file opening: first-class tabs with atomic external writes

- Rafu opens arbitrary **external** (outside-workspace-root) files as first-class editor tabs, on equal visual footing with workspace files.
- Edits to external files are saved atomically back to their original on-disk paths via `WorkspaceFileService.writeText`, not into the workspace.
- The editor preserves workspace-identity framing: external files are NOT added to the workspace tree and do NOT participate in workspace restore/persistence. Each open external file is ephemeral (lost on relaunch) and carries its full original path as identity.
- External files are opened via Finder drag-and-drop onto the editor canvas (split/move zones); explicit `File → Open` menu support is deferred to a future phase.

### Media preview boundary and matrix

The editor renders media content based on file type, with a built-in classification matrix:

| File type(s) | Preview | Notes |
|---|---|---|
| `.png`, `.jpeg`, `.jpg`, `.gif`, `.webp`, `.heic`, `.heif`, `.bmp`, `.tiff`, `.ico` | Bitmap image (existing `ImagePreviewView`) | Inline NSImage rendering |
| `.svg` | Vector image (NSImage native rendering) | Bounded by NSImage's native SVG support; no JS/animation; complex SVGs may mis-render |
| `.mp4`, `.mov`, `.m4v` | Video player (new `VideoPreviewView` via AVKit) | Inline video playback with AVKit `AVPlayer` |
| All other types, UTF-8 ≤4 MB | Editable text | Opened as text editor tab |
| Non-UTF-8 or >4 MB non-media | Error state | "Binary — no preview available"; specific friendlier error messaging is future scope |
| HTML, PDF | No preview (future scope) | Not added in this pass; WKWebView use remains blocked per ADR 0008 (web-view-per-document non-goal) |

**Video memory management:** `VideoPreviewView` releases its `AVPlayer` on `.onDisappear` (calls `replaceCurrentItem(with: nil)`) so hibernated or closed video tabs hold no playback resources and do not contribute to resident memory. Idle resident-memory budget (~150 MB per AGENTS.md) is preserved.

**SVG limitations (explicit, not bugs):** SVG previews use NSImage's bounded native support. No JavaScript execution, no CSS animation, and complex SVGs with nested groups or advanced filters may render incorrectly or not at all. This is a known limitation of NSImage's SVG parsing; improving it requires a proper SVG renderer (deferred).

### AVKit dependency and WKWebView non-goal clarification

- `VideoPreviewView` uses AVKit (Apple's native video framework) and is permitted. ADR 0008's non-goal is WKWebView-specific ("no shared WKWebView, no per-document web view"); AVKit is a different framework.
- No HTML or PDF web preview is added; that would require either a web view or a more sophisticated renderer, both deferred.

## Alternatives considered

- **Don't support external files.** Rejected — the user explicitly requested this, and it is a natural extension of drag-and-drop.
- **Add external files to the workspace tree.** Rejected — preserving workspace identity cleanly requires keeping external files separate and ephemeral.
- **Use a web view (WKWebView) for SVG/HTML/PDF preview.** Rejected per ADR 0008 (no per-document web views); defer until that non-goal is formally revisited.
- **Buffer non-UTF-8 files or files >4 MB.** Rejected — adding format detection and binary preview is out of scope for this pass; keep the threshold simple and document it.

## Consequences

- External files are now a first-class, visible type of editor tab. Users can open any file from their system via Finder drag-and-drop.
- Media files (images, video) display inline in the editor without requiring a separate application. This improves workflow for agents that generate or manipulate media.
- Editing an external file in Rafu and then opening it in another application will see Rafu's changes (atomic writes to the original path). No merge conflicts, but also no automatic reload in Rafu if another app edits it — that is consistent with Rafu's explicit-user-control philosophy (see AGENTS.md).
- Durable tradeoff: external file tabs are NOT restored across app relaunch. Workspace persistence (ADR 0006) covers only workspace-internal files. This keeps the persistence model clean and avoids dangling-link edge cases.
- **Residual limitations, explicit and deferred:**
  - SVG rendering is bounded by NSImage's parser; complex SVGs may mis-render (not a bug, a limitation of the tool).
  - Non-UTF-8 or >4 MB non-media files surface an error message; a friendlier "binary, no preview" state is future scope.
  - Sidebar file drops directly on the tab bar are now harmless no-ops (a minor usability gap; see `editor-tab-reorder-drop-zones.md`).

## Revisit trigger

Revisit if:
- A future phase adds per-document web views and wants to render HTML/PDF (would require re-evaluating ADR 0008).
- SVG rendering issues become frequent enough to justify a third-party SVG renderer.
- The >4 MB UTF-8 threshold or non-UTF-8 error handling needs to change based on user feedback.

## Related plan, reference, and implementation paths

- Reference: [`editor-tab-reorder-drop-zones.md`](../references/editor-tab-reorder-drop-zones.md) (Finder file-drop classification and zone handling)
- Reference: [`appkit-drag-destination-type-precedence.md`](../references/appkit-drag-destination-type-precedence.md) (pasteboard type classification that enables external file drops)
- Related ADR: [`0008-mermaid-native-preview.md`](0008-mermaid-native-preview.md) (bounded native rendering; web-view non-goal)
- Related ADR: [`0006-editor-working-set-hibernation.md`](0006-editor-working-set-hibernation.md) (persistence scope, workspace-internal files only)
- `Sources/RafuApp/Editor/EditorDragClassification.swift` — drop type classification
- `Sources/RafuApp/Editor/EditorDragAndDrop.swift` — Finder file-drop forwarding (`EditorDropForwarding.performFiles`)
- `Sources/RafuApp/Models/WorkspaceSession.swift` — `handleEditorFileDrops(paths:on:edge:)` routing and `trackNewDocument` for external files
- `Sources/RafuApp/Models/EditorDocument.swift` — `isVideo`, `videoExtensions` classification
- `Sources/RafuApp/Views/VideoPreviewView.swift` — AVKit video player (new)
- `Sources/RafuApp/Views/EditorCanvasView.swift` — `EditorDocumentView` video branch rendering
- `docs/plans/phases/pre-initial-push-workbench.md` — active phase
