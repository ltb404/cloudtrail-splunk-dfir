#!/usr/bin/env bash
#
# oneshot.sh - Load flattened CloudTrail NDJSON files into Splunk using
#              "splunk add oneshot".
#
# Usage:    ./oneshot.sh <ndjson_dir> [max_gb_per_run]
# Example:  ./oneshot.sh /data/cloudtrail_flat 40
#
# max_gb_per_run (optional) stops after roughly that many GB of files, which
# helps you stay under your daily Splunk license quota. Re-run the script the
# next day to continue; files already loaded are skipped (tracked in DONE_LOG).
#
# Environment variables (all optional):
#   SPLUNK_HOME   Splunk install path          (default: /opt/splunk)
#   INDEX         Target index                 (default: aws_cloudtrail)
#   SOURCETYPE    Sourcetype                   (default: aws:cloudtrail)
#   DONE_LOG      Log of already loaded files  (default: ./oneshot_done.log)
#   SPLUNK_AUTH   "user:password" if not already logged in via `splunk login`

set -euo pipefail

DIR="${1:?Usage: $0 <ndjson_dir> [max_gb_per_run]}"
MAX_GB="${2:-0}"

SPLUNK_HOME="${SPLUNK_HOME:-/opt/splunk}"
INDEX="${INDEX:-aws_cloudtrail}"
SOURCETYPE="${SOURCETYPE:-aws:cloudtrail}"
DONE_LOG="${DONE_LOG:-./oneshot_done.log}"

SPLUNK="$SPLUNK_HOME/bin/splunk"
[[ -x "$SPLUNK" ]] || { echo "ERROR: Splunk binary not found at $SPLUNK (set SPLUNK_HOME)." >&2; exit 1; }
[[ -d "$DIR" ]]    || { echo "ERROR: directory not found: $DIR" >&2; exit 1; }

touch "$DONE_LOG"
max_bytes=$(( MAX_GB * 1024 * 1024 * 1024 ))
loaded_bytes=0
loaded=0
failed=0

while IFS= read -r -d '' f; do
  # Skip files already loaded in a previous run
  grep -Fxq -- "$f" "$DONE_LOG" && continue

  size=$(stat -c %s "$f")
  if (( max_bytes > 0 && loaded_bytes + size > max_bytes )); then
    echo "Reached ~${MAX_GB} GB limit for this run. Re-run later to continue."
    break
  fi

  args=(add oneshot "$f" -index "$INDEX" -sourcetype "$SOURCETYPE")
  [[ -n "${SPLUNK_AUTH:-}" ]] && args+=(-auth "$SPLUNK_AUTH")

  if "$SPLUNK" "${args[@]}"; then
    echo "$f" >> "$DONE_LOG"
    loaded=$(( loaded + 1 ))
    loaded_bytes=$(( loaded_bytes + size ))
  else
    echo "FAILED: $f" >&2
    failed=$(( failed + 1 ))
  fi
done < <(find "$DIR" -type f -name '*.ndjson' -size +0 -print0 | sort -z)

gb=$(awk -v b="$loaded_bytes" 'BEGIN { printf "%.2f", b/1024/1024/1024 }')
echo
echo "Loaded $loaded file(s), ~${gb} GB this run. Failures: $failed."
(( failed == 0 )) || exit 2
