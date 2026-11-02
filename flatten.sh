#!/usr/bin/env bash
#
# flatten.sh - Convert exported AWS CloudTrail files to newline-delimited JSON
#              (one event per line) so Splunk can index them correctly.
#
# Handles:  *.tar.gz  (extracted first, then processed)
#           *.json.gz
#           *.json
# Skips:    macOS junk (._* files, .DS_Store)
#
# Usage:    ./flatten.sh <source_dir> <dest_dir> [parallel_jobs]
# Example:  ./flatten.sh /raw /data/cloudtrail_flat 4
#
# The region/year/month/day directory structure is preserved in <dest_dir>.
# Requires: bash, find, xargs, tar, zcat, jq

set -euo pipefail

SRC="${1:?Usage: $0 <source_dir> <dest_dir> [parallel_jobs]}"
DEST="${2:?Usage: $0 <source_dir> <dest_dir> [parallel_jobs]}"
JOBS="${3:-4}"

SRC="${SRC%/}"
DEST="${DEST%/}"
WORK="${DEST}_extracted"     # temporary area for extracted tar.gz contents
LOG="${DEST}_failed.log"     # failed files are listed here

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is not installed." >&2; exit 1; }
[[ -d "$SRC" ]] || { echo "ERROR: source directory not found: $SRC" >&2; exit 1; }

mkdir -p "$DEST" "$WORK"
: > "$LOG"

# --- Step 1: extract .tar.gz archives (mirroring the folder structure) -------
echo "Step 1/2: extracting .tar.gz archives..."
while IFS= read -r -d '' archive; do
  rel="${archive#"$SRC"/}"
  target="$WORK/$(dirname "$rel")"
  mkdir -p "$target"
  tar -xzf "$archive" -C "$target" --exclude='._*' --exclude='.DS_Store' \
    || echo "EXTRACT FAILED: $archive" >> "$LOG"
done < <(find "$SRC" -type f -name '*.tar.gz' ! -name '._*' -print0)

# --- Step 2: flatten each CloudTrail file to NDJSON --------------------------
flatten_one() {
  set -o pipefail
  local root="$1" f="$2"
  local rel="${f#"$root"/}"
  local out="$DEST/${rel%.gz}"
  out="${out%.json}.ndjson"
  mkdir -p "$(dirname "$out")"

  if [[ "$f" == *.gz ]]; then
    zcat "$f" | jq -c '.Records[]?' > "$out" || { echo "FLATTEN FAILED: $f" >> "$LOG"; rm -f "$out"; return 0; }
  else
    jq -c '.Records[]?' "$f" > "$out" || { echo "FLATTEN FAILED: $f" >> "$LOG"; rm -f "$out"; return 0; }
  fi

  # Remove outputs with no events (e.g. "Records":[] or digest files)
  [[ -s "$out" ]] || rm -f "$out"
}
export -f flatten_one
export DEST LOG

process_root() {
  local root="$1"
  find "$root" -type f \( -name '*.json.gz' -o -name '*.json' \) \
    ! -name '._*' ! -name '.DS_Store' -print0 \
    | xargs -0 -r -P "$JOBS" -I{} bash -c 'flatten_one "$0" "$1"' "$root" {}
}

echo "Step 2/2: flattening files with $JOBS parallel jobs..."
process_root "$SRC"
process_root "$WORK"

# --- Summary -----------------------------------------------------------------
out_count=$(find "$DEST" -type f -name '*.ndjson' | wc -l)
fail_count=$(wc -l < "$LOG")
echo
echo "Done. NDJSON files written: $out_count"
if (( fail_count > 0 )); then
  echo "WARNING: $fail_count failure(s). See $LOG (temporary files kept in $WORK)." >&2
  exit 2
fi

rm -rf "$WORK"
rm -f "$LOG"
echo "No failures."
echo "Next: ./oneshot.sh $DEST"
