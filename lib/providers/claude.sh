#!/usr/bin/env bash
# claude.sh — Anthropic Claude Code CLI adapter.
#
# The only provider that reports real dollar cost, and it enforces our schema
# natively via --json-schema, so output is structured rather than scraped.

provider_claude_bin() {
  local b; b="$(cfg_get '.providers.claude.bin' '')"
  [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(command -v claude 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  # Known install locations — a moved binary broke this once already.
  for b in "$HOME/.local/bin/claude" "/opt/homebrew/bin/claude" "/usr/local/bin/claude" \
           "$HOME/Library/Application Support/com.conductor.app/bin/claude"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

provider_claude_probe() {
  local bin ver auth logged method
  bin="$(provider_claude_bin || true)"
  if [ -z "$bin" ]; then
    jq -nc '{name:"claude",available:false,authed:false,note:"claude CLI not found"}'; return 0
  fi
  ver="$("$bin" --version 2>/dev/null | head -1)"
  auth="$("$bin" auth status 2>/dev/null)"
  logged="$(printf '%s' "$auth" | jq -r '.loggedIn // false' 2>/dev/null)"
  method="$(printf '%s' "$auth" | jq -r '(.subscriptionType // .authMethod) // ""' 2>/dev/null)"
  jq -nc --arg bin "$bin" --arg ver "$ver" --arg m "$method" --argjson logged "${logged:-false}" \
    '{name:"claude", available:true, authed:$logged, authMode:$m, version:$ver,
      costKnown:true, schemaMode:"native", bin:$bin, note:""}'
}

# provider_claude_review <prompt_file> <repo_dir> <schema> <out_json> <raw_dir>
provider_claude_review() {
  local pf="$1" dir="$2" schema="$3" out="$4" raw="$5"
  local bin model to t0 rc=0
  bin="$(provider_claude_bin)" || { GOBLIN_P_ERRKIND=other; GOBLIN_P_ERRMSG="claude not found"; return 1; }
  model="${GOBLIN_MODEL_OVERRIDE:-$(cfg_get '.providers.claude.model' 'sonnet')}"
  to="$(cfg_get '.timeoutSecs' 900)"
  t0="$(now_epoch)"

  # --tools "" removes all tool access: with the model no longer posting, it only
  # needs to read the prompt we already assembled. No bypassPermissions anywhere.
  #
  # The prompt goes in on STDIN, not as a positional arg: --tools is variadic and
  # would otherwise swallow the prompt as a tool name ("Input must be provided
  # either through stdin or as a prompt argument"). Redirecting from the prompt
  # file also keeps `claude -p`'s stdin drain away from the engine's PR loop.
  ( cd "$dir" 2>/dev/null || exit 1
    run_with_timeout "$to" "$bin" -p \
      --model "$model" \
      --output-format json \
      --json-schema "$(cat "$schema")" \
      --tools "" \
      > "$raw/stdout.json" 2> "$raw/stderr.txt" < "$pf"
  ) || rc=$?

  GOBLIN_P_DURATION_MS=$(( ($(now_epoch) - t0) * 1000 ))
  GOBLIN_P_MODEL="$model"
  GOBLIN_P_COST_KNOWN=true
  GOBLIN_P_COST_USD="$(jq -r '.total_cost_usd // 0' "$raw/stdout.json" 2>/dev/null)"
  [ -z "$GOBLIN_P_COST_USD" ] || [ "$GOBLIN_P_COST_USD" = "null" ] && GOBLIN_P_COST_USD=0
  GOBLIN_P_TOKENS_IN="$(jq -r '.usage.input_tokens // 0'  "$raw/stdout.json" 2>/dev/null)"
  GOBLIN_P_TOKENS_OUT="$(jq -r '.usage.output_tokens // 0' "$raw/stdout.json" 2>/dev/null)"
  GOBLIN_P_TURNS="$(jq -r '.num_turns // 0' "$raw/stdout.json" 2>/dev/null)"

  if [ "$rc" = "124" ]; then
    GOBLIN_P_ERRKIND=timeout; GOBLIN_P_ERRMSG="timed out after ${to}s"; return 124
  fi
  if [ "$rc" != "0" ]; then
    GOBLIN_P_ERRKIND="$(provider_classify_error "$(cat "$raw/stderr.txt" 2>/dev/null)")"
    GOBLIN_P_ERRMSG="$(head -c 300 "$raw/stderr.txt" 2>/dev/null)"
    return 1
  fi
  if [ "$(jq -r '.is_error // false' "$raw/stdout.json" 2>/dev/null)" = "true" ]; then
    GOBLIN_P_ERRKIND=other
    GOBLIN_P_ERRMSG="$(jq -r '.result // "model reported an error"' "$raw/stdout.json" 2>/dev/null | head -c 300)"
    return 1
  fi

  # --json-schema gives a parsed object; fall back to the raw text if absent.
  if jq -e '.structured_output | type == "object"' "$raw/stdout.json" >/dev/null 2>&1; then
    jq '.structured_output' "$raw/stdout.json" > "$out"
    return 0
  fi
  jq -r '.result // ""' "$raw/stdout.json" > "$raw/last.txt" 2>/dev/null
  findings_extract "$raw/last.txt" "$out" && return 0
  GOBLIN_P_ERRKIND=bad_output; GOBLIN_P_ERRMSG="no JSON in response"
  return 2
}
