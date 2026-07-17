; Hand-authored for Rafu (increment A, symbol-coverage lane) — tree-sitter-bash
; ships no upstream tags.scm; verified against src/node-types.json's
; `function_definition` node (`name` field, `word` type).

(function_definition name: (word) @name) @definition.function
