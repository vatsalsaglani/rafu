# Pre-first-commit vertical slice

## Status

Active. This brief supersedes bootstrap placeholder scope until the repository's
first commit exists. It does not supersede the product architecture invariants.

## Purpose

The first Git commit must demonstrate Rafu's core reason to exist: a small native
macOS editor can open this repository, make a focused edit, inspect source
control, and create the commit without another editor.

## Acceptance contract

- Open a local folder and present a formatted, hierarchical file tree.
- Open multiple files as tabs; edit and save text with native TextKit and useful
  syntax color for common repository formats.
- Support independent workspace windows whose title identifies the workspace and
  selected file.
- File context menus provide rename, copy relative path, copy absolute path, and
  copy-file pasteboard actions.
- Markdown has a native preview, including a useful Mermaid subset for flowcharts
  and sequence diagrams. No per-document web view is introduced.
- If the workspace is a Git repository, a right inspector shows branch and
  changes, can stage/unstage files, accepts a commit message, and can commit.
- Settings selects System, Indigo, or Khadi using the bundled JSON themes.
- The empty workspace uses the supplied seam SVG, the `Rafu / રફૂ` wordmark, and
  the zari-like repaired underline. Native macOS 26 glass is visible on suitable
  branded/custom surfaces, with material fallbacks on macOS 15–25.
- The app is built, launched as a real `.app`, checked with a second window, and
  used to create the repository's first commit. No shell or other editor may
  create that commit.

## Architecture boundaries

- SwiftUI owns scene, split-view, tab metadata, inspector, settings, and commands.
- `NSTextView`/`NSTextStorage` own live document text. Observable state contains
  only document identity, dirty/revision state, and UI selection metadata.
- Filesystem and Git work use explicit services and argument arrays. No user path
  is interpolated into a shell command.
- File loading is bounded: skip generated/heavy directories and refuse oversized
  text buffers with a clear error.
- Theme files remain the source of truth; UI colors are decoded, not duplicated.

## Verification

1. `./script/format.sh --lint`
2. `swift test`
3. `./script/build_and_run.sh --verify`
4. Open this repository, expand nested directories, edit and save a Swift and a
   Markdown file, render a Mermaid block, exercise every file context action,
   open a second window, stage all files, and commit from Rafu.

