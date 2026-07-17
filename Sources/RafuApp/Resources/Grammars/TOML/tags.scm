; Hand-authored for Rafu (increment B, symbol-coverage lane) — tree-sitter-toml
; ships no upstream tags.scm; verified against src/node-types.json: `document`
; has direct children `pair`/`table`/`table_array_element`; `table` and
; `table_array_element` have direct-child `bare_key`/`dotted_key`/
; `quoted_key`/`pair`, and a `pair`'s own `bare_key` is a child of `pair`, not
; of `table`. Table/array-of-tables names are captured as `definition.class`;
; top-level and table-nested bare-key pairs are captured as
; `definition.property`. `inline_table` pairs are intentionally excluded
; (value data, not config keys).

(table (bare_key) @name) @definition.class
(table (dotted_key) @name) @definition.class
(table_array_element (bare_key) @name) @definition.class
(table_array_element (dotted_key) @name) @definition.class

(document (pair (bare_key) @name) @definition.property)
(table (pair (bare_key) @name) @definition.property)
(table_array_element (pair (bare_key) @name) @definition.property)
