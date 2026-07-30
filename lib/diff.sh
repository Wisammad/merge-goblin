#!/usr/bin/env bash
# diff.sh — build (a) a line-numbered diff for the model and (b) the set of
# positions GitHub will actually accept a comment on.
#
# Why (b) matters: POST /pulls/{n}/reviews with comments[] is ALL-OR-NOTHING.
# One comment on a line that isn't in the diff 422s the entire review and every
# other finding is lost. So we validate before posting, never after.
#
# The jq programs live in share/jq/*.jq and are run with `jq -f`: keeping them
# out of shell quoting removes a whole class of escaping bugs and lets them be
# tested standalone.

# diff_fetch_files <slug> <pr> <out.json>
# GitHub's files payload is the source of truth for what is addressable — the
# local checkout can legitimately differ from what GitHub thinks the diff is.
diff_fetch_files() {
  local slug="$1" pr="$2" out="$3"
  gh api --paginate "repos/$slug/pulls/$pr/files?per_page=100" \
    --jq '.[] | {filename, status, additions, deletions, patch}' 2>/dev/null \
    | jq -s '.' > "$out" 2>/dev/null
  if ! jq -e 'type == "array" and length > 0' "$out" >/dev/null 2>&1; then
    echo '[]' > "$out"; return 1
  fi
  return 0
}

diff_addressable() { jq -f "$SHARE_DIR/jq/addressable.jq" "$1" > "$2"; }

# diff_annotated <files.json> <out.diff> [max_bytes]
diff_annotated() {
  local files="$1" out="$2" max="${3:-400000}"
  jq -r -f "$SHARE_DIR/jq/annotate.jq" "$files" 2>/dev/null | head -c "$max" > "$out"

  if [ "$(wc -c < "$out" 2>/dev/null || echo 0)" -ge "$max" ]; then
    printf '\n\n[diff truncated at %s bytes — review what is shown above]\n' "$max" >> "$out"
  fi

  # Files with no patch (binary, or too large for GitHub to diff) still matter —
  # the model should know they changed even though it can't comment on lines.
  local nopatch
  nopatch="$(jq -r '.[] | select(.patch == null) | "  \(.filename) (\(.status))"' "$files" 2>/dev/null)"
  if [ -n "$nopatch" ]; then
    { printf '\n\nChanged files with no inline diff available (reference these by path only):\n'
      printf '%s\n' "$nopatch"; } >> "$out"
  fi
}

# diff_split_findings <normalized.json> <addressable.json> <out.json>
diff_split_findings() {
  jq --slurpfile ok "$2" -f "$SHARE_DIR/jq/split-findings.jq" "$1" > "$3"
}
