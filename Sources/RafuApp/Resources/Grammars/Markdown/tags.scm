; Hand-authored for Rafu (increment C, symbol-coverage lane) — tree-sitter-
; markdown ships no upstream tags.scm; verified against src/node-types.json:
; `document` -> `section` (which nests recursively) -> `atx_heading`/
; `setext_heading`. `atx_heading`'s text lives in its `heading_content` field,
; typed `inline`; `setext_heading`'s text lives in its `heading_content`
; field, typed `paragraph`. Both are captured as `definition.section` so
; Markdown headings surface in the workspace symbol index without competing
; with code definition kinds; the navigation provider filters `section` out
; of go-to-definition/declaration answers (see
; `WorkspaceSymbolExtractor.navigableKinds`) so headings only ever answer `#`
; search.

(atx_heading (inline) @name) @definition.section
(setext_heading (paragraph) @name) @definition.section
