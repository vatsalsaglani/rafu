; Hand-authored for Rafu (increment B, symbol-coverage lane) — tree-sitter-yaml
; ships no upstream tags.scm; verified against src/node-types.json:
; `stream` -> `document` -> `block_node` -> `block_mapping` ->
; `block_mapping_pair` (fields `key`/`value`); `anchor` -> `anchor_name`.
; Captures only top-level scalar mapping keys — a nested mapping key's
; ancestor chain runs through an extra `block_mapping_pair`/`block_node`
; pair, so it does not match this exact ancestry and is structurally
; excluded — plus YAML anchors at any depth. Accepted limitations:
; flow-style root maps and complex (block_node) keys are not captured.

(anchor (anchor_name) @name) @definition.constant

(document
  (block_node
    (block_mapping
      (block_mapping_pair
        key: (flow_node) @name) @definition.property)))
