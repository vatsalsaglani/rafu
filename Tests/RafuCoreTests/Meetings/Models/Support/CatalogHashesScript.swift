// The developer script that filled the SHA-256 values and sizes of
// `MeetingModelCatalog` on 2026-11-23. It is kept as text in this comment, so
// it is not compiled, not run by a test, and not a package resource. To use
// it, copy the lines below the marker into a `.sh` file and remove the
// leading "// " of each line.
//
// Results on 2026-11-23: 62 files; each LFS hash matched the tree API at the
// pinned revision; each git file matched its git blob id; the nine values that
// the speech spike recorded (five Nemotron 3, four SpeakerKit) matched.

// ----- script -----
// #!/usr/bin/env bash
// # Meeting model catalog: developer step, one time, NOT run by a test or the app.
// #
// # It prints one line for each catalog file at a pinned Hugging Face revision:
// #   <remote path> <bytes> <sha-256> <source>
// # where <source> is
// #   lfs        the `lfs.oid` of the Hugging Face tree API (the SHA-256 of an LFS
// #              file). When LOCAL_DIR holds a copy, that copy is hashed and must
// #              equal `lfs.oid`, else the run stops.
// #   download   no `lfs.oid`; the file was downloaded at the pinned revision into a
// #              new empty scratch folder and hashed here. Its git blob SHA-1 is
// #              checked against the tree API `oid`, so a wrong download stops the run.
// #   local      no `lfs.oid`; a local copy (LOCAL_DIR) was hashed, after the same
// #              git blob SHA-1 check.
// #
// # Usage (copy to a .sh file first; needs curl, jq, shasum, git):
// #   catalog-hashes.sh <repo> <revision> <prefix> <scratch dir> [LOCAL_DIR] < paths.txt
// #   paths.txt: one remote path for each line, relative to the repository root.
// #   LOCAL_DIR maps a remote path with <prefix> removed to a local file.
// #
// # Sends no user or project name; the User-Agent is a generic client name.
// # The scratch folder holds untrusted downloads: use a new empty folder.
// # Used on 2026-11-23 to fill Sources/RafuCore/Meetings/Models/MeetingModelCatalog.swift.
// set -euo pipefail
// repo="$1"; rev="$2"; prefix="$3"; scratch="$4"; local_dir="${5:-}"
// ua="model-catalog-check/1.0"
// mkdir -p "$scratch"
// tree="$scratch/tree.json"
// curl -fsSL -A "$ua" "https://huggingface.co/api/models/$repo/tree/$rev?recursive=true" -o "$tree"
// while IFS= read -r path; do
//   [ -n "$path" ] || continue
//   row=$(jq -c --arg p "$path" '.[]|select(.type=="file" and .path==$p)' "$tree")
//   [ -n "$row" ] || { echo "MISSING upstream: $path" >&2; exit 1; }
//   size=$(jq -r '.size' <<<"$row"); oid=$(jq -r '.oid' <<<"$row")
//   lfs=$(jq -r '.lfs.oid // empty' <<<"$row")
//   rel="${path#"$prefix"}"
//   if [ -n "$lfs" ]; then
//     if [ -n "$local_dir" ] && [ -f "$local_dir/$rel" ]; then
//       got=$(shasum -a 256 "$local_dir/$rel" | cut -d' ' -f1)
//       [ "$got" = "$lfs" ] || { echo "MISMATCH lfs $path $got != $lfs" >&2; exit 1; }
//       lsize=$(stat -f %z "$local_dir/$rel")
//       [ "$lsize" = "$size" ] || { echo "MISMATCH size $path" >&2; exit 1; }
//     fi
//     echo "$path $size $lfs lfs"
//   else
//     if [ -n "$local_dir" ] && [ -f "$local_dir/$rel" ]; then
//       file="$local_dir/$rel"; src=local
//     else
//       dir=$(mktemp -d "$scratch/dl.XXXXXX")
//       file="$dir/blob"; src=download
//       curl -fsSL -A "$ua" "https://huggingface.co/$repo/resolve/$rev/$path" -o "$file"
//     fi
//     blob=$(git hash-object --no-filters "$file")
//     [ "$blob" = "$oid" ] || { echo "MISMATCH git oid $path $blob != $oid" >&2; exit 1; }
//     lsize=$(stat -f %z "$file")
//     [ "$lsize" = "$size" ] || { echo "MISMATCH size $path" >&2; exit 1; }
//     echo "$path $size $(shasum -a 256 "$file" | cut -d' ' -f1) $src"
//   fi
// done
