#!/usr/bin/env bash
# findings.sh — turn whatever the model said into a validated findings object.

# findings_extract <candidate_text_file> <out_json>
# Models wrap JSON in prose or fences even when told not to. Try, in order:
#   1. the whole file is JSON
#   2. a ```json fenced block
#   3. the widest {...} span
findings_extract() {
  local src="$1" out="$2"
  [ -s "$src" ] || return 1

  if jq -e . "$src" >/dev/null 2>&1; then cp "$src" "$out"; return 0; fi

  # Content of fenced code blocks.
  local tmp="$out.cand"
  awk 'BEGIN{inb=0}
       /^[[:space:]]*```/ { inb = !inb; next }
       inb { print }' "$src" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then mv "$tmp" "$out"; return 0; fi

  # Widest brace span, sliced by CHARACTER not by line: models routinely put the
  # preamble on the same line as the JSON ("I'll review the diff...{...}"), which
  # a line-based slice keeps and jq then rejects.
  perl -0777 -ne 'my $i = index($_, "{"); my $j = rindex($_, "}");
                  print substr($_, $i, $j - $i + 1) if $i >= 0 && $j > $i;' \
    "$src" > "$tmp" 2>/dev/null
  if [ -s "$tmp" ] && jq -e . "$tmp" >/dev/null 2>&1; then mv "$tmp" "$out"; return 0; fi

  rm -f "$tmp" 2>/dev/null
  return 1
}

findings_validate() { jq -e -f "$SHARE_DIR/jq/validate.jq" "$1" >/dev/null 2>"$2"; }

# findings_normalize <in> <out> — defaults, dedupe, severity sort, cap, stable ids.
findings_normalize() {
  local in="$1" out="$2" max
  max="$(cfg_get '.maxFindings' 25)"
  jq --argjson max "$max" -f "$SHARE_DIR/jq/normalize.jq" "$in" > "$out.stage" 2>/dev/null || return 1

  # Hash idRaw -> short stable id (jq has no hash function).
  local n i raw id
  n="$(jq '.findings | length' "$out.stage" 2>/dev/null || echo 0)"
  cp "$out.stage" "$out"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    raw="$(jq -r --argjson i "$i" '.findings[$i].idRaw' "$out")"
    id="$(goblin_hash "$raw")"
    jq --argjson i "$i" --arg id "$id" '.findings[$i].id = $id | del(.findings[$i].idRaw)' \
      "$out" > "$out.t" && mv "$out.t" "$out"
    i=$((i + 1))
  done
  rm -f "$out.stage" 2>/dev/null
  return 0
}

# findings_counts <file> -> "blocker convention risk nit question total"
findings_counts() {
  jq -r '[.findings[]?.severity] as $s
    | [ ($s|map(select(.=="blocker"))|length),
        ($s|map(select(.=="convention"))|length),
        ($s|map(select(.=="risk"))|length),
        ($s|map(select(.=="nit"))|length),
        ($s|map(select(.=="question"))|length),
        ($s|length) ] | @tsv' "$1" 2>/dev/null
}

# The engine decides the verdict; the model's suggestion is only a hint.
# Default policy never approves and never blocks under a human's account.
findings_verdict() {
  local file="$1" mode blockers total
  mode="$(cfg_get '.verdictMode' 'comment')"
  blockers="$(jq '[.findings[]? | select(.severity=="blocker")] | length' "$file" 2>/dev/null || echo 0)"
  total="$(jq '.findings | length' "$file" 2>/dev/null || echo 0)"
  case "$mode" in
    request-changes)
      if [ "${blockers:-0}" -gt 0 ]; then echo REQUEST_CHANGES; else echo COMMENT; fi ;;
    full)
      if [ "${blockers:-0}" -gt 0 ]; then echo REQUEST_CHANGES
      elif [ "$(cfg_get '.allowApprove' false)" = "true" ] && [ "${total:-0}" -eq 0 ]; then echo APPROVE
      else echo COMMENT; fi ;;
    *) echo COMMENT ;;
  esac
}

# The model subprocess runs a third-party CLI with an untrusted PR checkout as
# its working directory. engine_auth exports GH_TOKEN and the GIT_CONFIG_* URL
# rewrite process-wide so git can authenticate without the keychain (launchd
# cannot reach it), which means the model would otherwise inherit a live
# credential for every repo the reviewer can see. Adapters disable tools, but
# that is a per-provider flag and the only thing standing between a prompt
# injection in a diff and a usable token — so the credential does not go in the
# environment at all.
#
# Scrub/restore live here because findings_run is the single place any provider
# CLI is executed, so a future adapter cannot forget it. They are not wrapped in
# a subshell: adapters must set their GOBLIN_P_* result globals in the caller's
# shell. Indirect expansion is done with eval, not ${!v}, for bash 3.2.
GOBLIN_SCRUB_VARS="GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0"

findings_scrub_env() {
  local v
  for v in $GOBLIN_SCRUB_VARS; do
    if eval "[ \"\${${v}+set}\" = set ]"; then
      eval "GOBLIN_SAVED_${v}=\${${v}}"
      eval "GOBLIN_HAD_${v}=1"
      unset "$v"
    else
      eval "GOBLIN_HAD_${v}=0"
    fi
  done
}

findings_restore_env() {
  local v had
  for v in $GOBLIN_SCRUB_VARS; do
    eval "had=\${GOBLIN_HAD_${v}:-0}"
    # An empty value is still a value: restore only what was actually set, so a
    # scrub can never invent GH_TOKEN="" and mask a real auth failure later.
    [ "$had" = 1 ] && eval "export ${v}=\${GOBLIN_SAVED_${v}}"
    eval "unset GOBLIN_SAVED_${v} GOBLIN_HAD_${v}"
  done
}

# findings_invoke <provider> <prompt_file> <repo_dir> <out> <raw_dir>
# The only call site of a provider adapter. Returns the adapter's exit code.
findings_invoke() {
  local prov="$1" rc=0
  findings_scrub_env
  "provider_${prov}_review" "$2" "$3" "$SCHEMA_FILE" "$4" "$5" || rc=$?
  findings_restore_env
  return $rc
}

# findings_run <provider> <prompt_file> <repo_dir> <out_json> <raw_dir>
# One repair retry, then give up. Returns 0 with a validated, normalized file.
findings_run() {
  local prov="$1" pf="$2" dir="$3" out="$4" raw="$5"
  local rc errf="$raw/validate.err" tmp="$raw/raw-findings.json"

  findings_invoke "$prov" "$pf" "$dir" "$tmp" "$raw"; rc=$?

  if [ "$rc" -eq 0 ] && findings_validate "$tmp" "$errf"; then
    findings_normalize "$tmp" "$out"; return $?
  fi
  # A transport failure or timeout is not something a reprompt can fix.
  if [ "$rc" -eq 1 ] || [ "$rc" -eq 124 ]; then return "$rc"; fi

  log "  output rejected ($(head -c 120 "$errf" 2>/dev/null)) — retrying once"
  local pf2="$raw/prompt-repair.txt"
  {
    cat "$pf"
    printf '\n\n---\n\nYour previous response was rejected: %s\n' "$(head -c 200 "$errf" 2>/dev/null)"
    printf 'Return ONLY the JSON object described above. No prose, no markdown fence.\n'
  } > "$pf2"

  findings_invoke "$prov" "$pf2" "$dir" "$tmp" "$raw"; rc=$?
  if [ "$rc" -eq 0 ] && findings_validate "$tmp" "$errf"; then
    findings_normalize "$tmp" "$out"; return $?
  fi
  GOBLIN_P_ERRKIND=bad_output
  GOBLIN_P_ERRMSG="invalid output after retry: $(head -c 200 "$errf" 2>/dev/null)"
  return 2
}
