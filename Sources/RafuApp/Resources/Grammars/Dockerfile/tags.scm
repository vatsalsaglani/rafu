; Hand-authored for Rafu (increment A, symbol-coverage lane) — tree-sitter-dockerfile
; ships no upstream tags.scm; verified against src/node-types.json's
; `from_instruction` node (`as` field, `image_alias` type).

(from_instruction as: (image_alias) @name) @definition.class
