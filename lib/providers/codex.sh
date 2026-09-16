#!/usr/bin/env bash
# codex.sh — OpenAI Codex CLI adapter (ChatGPT subscription auth).
#
# Enforces our schema natively via --output-schema. Subscription auth means no
# dollar figure is reported; the engine falls back to counting reviews.

provider_codex_bin() {
  local b; b="$(cfg_get '.providers.codex.bin' '')"
  [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(command -v codex 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  for b in "/opt/homebrew/bin/codex" "/usr/local/bin/codex" "$HOME/.local/bin/codex"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

provider_codex_probe() {
  local bin ver authed=false mode="" model
  bin="$(provider_codex_bin || true)"
  if [ -z "$bin" ]; then
    jq -nc '{name:"codex",available:false,authed:false,note:"codex CLI not found"}'; return 0
  fi
  ver="$("$bin" --version 2>/dev/null | head -1)"
  # auth.json is written by `codex login`; auth_mode distinguishes ChatGPT
  # subscription from an API key.
  if [ -f "$HOME/.codex/auth.json" ]; then
    mode="$(jq -r '.auth_mode // ""' "$HOME/.codex/auth.json" 2>/dev/null)"
    if jq -e '(.tokens != null) or (.OPENAI_API_KEY != null and .OPENAI_API_KEY != "")' \
         "$HOME/.codex/auth.json" >/dev/null 2>&1; then authed=true; fi
  fi
  model="$(cfg_get '.providers.codex.model' '')"
  [ -z "$model" ] && model="$(grep -E '^model *=' "$HOME/.codex/config.toml" 2>/dev/null | head -1 | sed 's/.*= *//; s/"//g')"
  jq -nc --arg bin "$bin" --arg ver "$ver" --arg m "${mode:-unknown}" --arg model "$model" \
     --argjson authed "$authed" \
    '{name:"codex", available:true, authed:$authed, authMode:$m, version:$ver, model:$model,
      costKnown:false, schemaMode:"native-file", bin:$bin,
      note:(if $authed then "" else "run: codex login" end)}'
}

provider_codex_review() {
  local pf="$1" dir="$2" schema="$3" out="$4" raw="$5"
  local bin model eff to t0 rc=0
  bin="$(provider_codex_bin)" || { GOBLIN_P_ERRKIND=other; GOBLIN_P_ERRMSG="codex not found"; return 1; }
  model="$(cfg_get '.providers.codex.model' '')"
  eff="$(cfg_get '.providers.codex.reasoningEffort' 'medium')"
  to="$(cfg_get '.timeoutSecs' 900)"
  t0="$(now_epoch)"

  # OpenAI's structured-output dialect is stricter than JSON Schema: every
  # property must be listed in `required` (optional fields become nullable
  # unions), else the API rejects the request with invalid_json_schema.
  local strict="$SHARE_DIR/schema/findings.strict.schema.json"
  [ -f "$strict" ] && schema="$strict"

  set -- exec --cd "$dir" --sandbox read-only --skip-git-repo-check \
        --output-schema "$schema" --output-last-message "$raw/last.txt" --json
  [ -n "$model" ] && set -- "$@" --model "$model"
  [ -n "$eff" ]   && set -- "$@" -c "model_reasoning_effort=\"$eff\""
  # The user's own config.toml can load plugins, MCP servers and hooks that are
  # slow or interactive — unsuitable under launchd. --ignore-user-config drops
  # those, but it ALSO drops cli_auth_credentials_store="file", which would send
  # codex to the keychain (unreachable from a background agent), so put it back.
  set -- "$@" --ignore-user-config -c 'cli_auth_credentials_store="file"'

  # `codex exec -` reads the prompt from stdin, which avoids both argv length
  # limits on large diffs and any flag/positional ambiguity.
  run_with_timeout "$to" "$bin" "$@" - \
    > "$raw/stdout.jsonl" 2> "$raw/stderr.txt" < "$pf" || rc=$?

  GOBLIN_P_DURATION_MS=$(( ($(now_epoch) - t0) * 1000 ))
  GOBLIN_P_MODEL="${model:-codex-default}"
  GOBLIN_P_COST_KNOWN=false
  GOBLIN_P_COST_USD=0
  # Token usage does come through the event stream even though cost doesn't.
  GOBLIN_P_TOKENS_IN="$(jq -rs '[.[]? | .. | objects | .input_tokens? // empty] | last // 0' "$raw/stdout.jsonl" 2>/dev/null)"
  GOBLIN_P_TOKENS_OUT="$(jq -rs '[.[]? | .. | objects | .output_tokens? // empty] | last // 0' "$raw/stdout.jsonl" 2>/dev/null)"
  GOBLIN_P_TURNS=0

  if [ "$rc" = "124" ]; then GOBLIN_P_ERRKIND=timeout; GOBLIN_P_ERRMSG="timed out after ${to}s"; return 124; fi
  if [ "$rc" != "0" ]; then
    # Codex reports the real failure as a JSON event on STDOUT; stderr carries
    # unrelated noise. Reading stderr alone told the operator "failed to refresh
    # available models: timeout waiting for child process to exit" when what had
    # actually happened was "You hit your spend cap set by the owner of your
    # workspace" -- a different problem with a different fix, and the actionable
    # sentence was on disk the whole time. Prefer stdout, fall back to stderr.
    local cx_msg
    cx_msg="$(jq -rs '[.[]? | select(.type=="error" or .type=="turn.failed")
                        | (.message // .error.message // empty)] | last // empty' \
                "$raw/stdout.jsonl" 2>/dev/null)"
    [ -z "$cx_msg" ] && cx_msg="$(head -c 300 "$raw/stderr.txt" 2>/dev/null)"
    [ -z "$cx_msg" ] && cx_msg="codex exited $rc with no output"
    GOBLIN_P_ERRKIND="$(provider_classify_error "$cx_msg")"
    GOBLIN_P_ERRMSG="$(printf '%s' "$cx_msg" | head -c 300)"
    return 1
  fi

  findings_extract "$raw/last.txt" "$out" && return 0
  GOBLIN_P_ERRKIND=bad_output; GOBLIN_P_ERRMSG="no JSON in final message"
  return 2
}
