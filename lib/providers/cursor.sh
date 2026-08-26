#!/usr/bin/env bash
# cursor.sh — Cursor CLI adapter (Cursor subscription auth).
#
# Best-effort: cursor-agent has no schema flag, so the output contract is
# enforced by the prompt and repaired by findings_extract. Install with:
#   curl https://cursor.com/install -fsS | bash

provider_cursor_bin() {
  local b; b="$(cfg_get '.providers.cursor.bin' '')"
  [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(command -v cursor-agent 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  for b in "$HOME/.local/bin/cursor-agent" "/opt/homebrew/bin/cursor-agent" "$HOME/.cursor/bin/cursor-agent"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

provider_cursor_probe() {
  local bin ver authed=false
  bin="$(provider_cursor_bin || true)"
  if [ -z "$bin" ]; then
    jq -nc '{name:"cursor",available:false,authed:false,
             note:"not installed — curl https://cursor.com/install -fsS | bash"}'
    return 0
  fi
  ver="$("$bin" --version 2>/dev/null | head -1)"
  # `cursor-agent status` exits 0 even when signed out, so the exit code says
  # nothing — read what it actually printed.
  local st; st="$("$bin" status 2>/dev/null)"
  case "$(lc "$st")" in
    *"not logged in"*|*"not authenticated"*|*"no active"*|"") authed=false ;;
    *) authed=true ;;
  esac
  jq -nc --arg bin "$bin" --arg ver "$ver" --argjson authed "$authed" \
    '{name:"cursor", available:true, authed:$authed, authMode:"cursor", version:$ver,
      costKnown:false, schemaMode:"prompt-only", bin:$bin,
      note:(if $authed then "" else "run: cursor-agent login" end)}'
}

# provider_cursor_invoke <bin> <dir> <timeout> <prompt> <raw> [model]
# One `cursor-agent -p` call. Split out so the caller can make it twice — see
# the model fallback below.
provider_cursor_invoke() {
  local bin="$1" dir="$2" to="$3" pf="$4" raw="$5" model="${6:-}" rc=0
  # cursor-agent refuses to run in an untrusted directory and asks interactively,
  # which never completes under launchd. --force trusts the directory; safe here
  # because the review needs read access only — it has no tools to post with and
  # the repo is a throwaway scratch clone.
  set -- -p --output-format json --force
  [ -n "$model" ] && set -- "$@" --model "$model"

  ( cd "$dir" 2>/dev/null || exit 1
    run_with_timeout "$to" "$bin" "$@" \
      > "$raw/stdout.json" 2> "$raw/stderr.txt" < "$pf"
  ) || rc=$?
  return "$rc"
}

provider_cursor_review() {
  local pf="$1" dir="$2" schema="$3" out="$4" raw="$5"
  local bin model to t0 rc=0
  bin="$(provider_cursor_bin)" || { GOBLIN_P_ERRKIND=other; GOBLIN_P_ERRMSG="cursor-agent not found"; return 1; }
  model="${GOBLIN_MODEL_OVERRIDE:-$(cfg_get '.providers.cursor.model' '')}"
  to="$(cfg_get '.timeoutSecs' 900)"
  t0="$(now_epoch)"

  provider_cursor_invoke "$bin" "$dir" "$to" "$pf" "$raw" "$model" || rc=$?

  # A model id this cursor-agent build does not know is a hard, immediate refusal
  # ("Cannot use this model: X. Available models: ..."), not a review that failed.
  # The Goblin names a model by default now, so an older CLI than the one that
  # default was chosen against would otherwise fail every review it is asked for
  # with an opaque provider error. Fall back to the CLI's own pick and say so,
  # rather than reviewing nothing at all.
  if [ "$rc" != "0" ] && [ -n "$model" ] \
     && grep -qi 'cannot use this model' "$raw/stderr.txt" 2>/dev/null; then
    log "  cursor-agent does not know '$model' — retrying with its own default model"
    model=""; rc=0
    provider_cursor_invoke "$bin" "$dir" "$to" "$pf" "$raw" "" || rc=$?
  fi

  GOBLIN_P_DURATION_MS=$(( ($(now_epoch) - t0) * 1000 ))
  GOBLIN_P_MODEL="${model:-cursor-auto}"
  GOBLIN_P_COST_KNOWN=false; GOBLIN_P_COST_USD=0
  GOBLIN_P_TOKENS_IN=0; GOBLIN_P_TOKENS_OUT=0; GOBLIN_P_TURNS=0

  if [ "$rc" = "124" ]; then GOBLIN_P_ERRKIND=timeout; GOBLIN_P_ERRMSG="timed out after ${to}s"; return 124; fi
  if [ "$rc" != "0" ]; then
    GOBLIN_P_ERRKIND="$(provider_classify_error "$(cat "$raw/stderr.txt" 2>/dev/null)")"
    GOBLIN_P_ERRMSG="$(head -c 300 "$raw/stderr.txt" 2>/dev/null)"
    return 1
  fi

  # Unknown envelope shape: try the common text fields, then the raw stdout.
  jq -r '(.result // .response // .text // .message // empty)' "$raw/stdout.json" \
    > "$raw/last.txt" 2>/dev/null
  [ -s "$raw/last.txt" ] || cp "$raw/stdout.json" "$raw/last.txt" 2>/dev/null

  findings_extract "$raw/last.txt" "$out" && return 0
  GOBLIN_P_ERRKIND=bad_output; GOBLIN_P_ERRMSG="no JSON in response"
  return 2
}
