#!/usr/bin/env bash
# opencode.sh — OpenCode CLI adapter (OpenCode Zen models, e.g. DeepSeek).
#
# Like cursor, opencode has no schema flag, so the output contract is enforced by
# the prompt and repaired by findings_extract. The default model is free and needs
# no login; a paid Zen model needs credits on the account (opencode.ai/console).
# Install with:  curl -fsSL https://opencode.ai/install | bash

provider_opencode_bin() {
  local b; b="$(cfg_get '.providers.opencode.bin' '')"
  [ -n "$b" ] && [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  b="$(command -v opencode 2>/dev/null)"
  [ -n "$b" ] && { printf '%s' "$b"; return 0; }
  for b in "$HOME/.opencode/bin/opencode" "$HOME/.local/bin/opencode" "/opt/homebrew/bin/opencode"; do
    [ -x "$b" ] && { printf '%s' "$b"; return 0; }
  done
  return 1
}

# Installed is all a probe can check: the free default model needs no account, and
# a paid model without credits only shows at review time ("Insufficient account
# funds", which provider_classify_error files under quota).
provider_opencode_probe() {
  local bin ver
  bin="$(provider_opencode_bin || true)"
  if [ -z "$bin" ]; then
    jq -nc '{name:"opencode",available:false,authed:false,
             note:"not installed — curl -fsSL https://opencode.ai/install | bash"}'
    return 0
  fi
  ver="$("$bin" --version 2>/dev/null | head -1)"
  jq -nc --arg bin "$bin" --arg ver "$ver" \
    '{name:"opencode", available:true, authed:true, authMode:"opencode zen", version:$ver,
      costKnown:false, schemaMode:"prompt-only", bin:$bin, note:""}'
}

provider_opencode_review() {
  local pf="$1" dir="$2" schema="$3" out="$4" raw="$5"
  local bin model t0 rc=0
  bin="$(provider_opencode_bin)" || { GOBLIN_P_ERRKIND=other; GOBLIN_P_ERRMSG="opencode not found"; return 1; }
  model="${GOBLIN_MODEL_OVERRIDE:-$(cfg_get '.providers.opencode.model' '')}"
  model="${model:-$GOBLIN_OPENCODE_DEFAULT_MODEL}"
  t0="$(now_epoch)"

  # The `plan` agent is opencode's read-only one: the review reads the scratch
  # clone and must not edit it. The prompt goes on stdin, since a whole diff can
  # exceed Linux's 128 KiB limit for a single argument.
  ( cd "$dir" 2>/dev/null || exit 1
    "$bin" run --agent plan --format json --model "$model" \
      > "$raw/stdout.json" 2> "$raw/stderr.txt" < "$pf"
  ) || rc=$?

  GOBLIN_P_DURATION_MS=$(( ($(now_epoch) - t0) * 1000 ))
  GOBLIN_P_MODEL="$model"
  GOBLIN_P_COST_KNOWN=false; GOBLIN_P_COST_USD=0
  GOBLIN_P_TOKENS_IN=0; GOBLIN_P_TOKENS_OUT=0; GOBLIN_P_TURNS=0

  # Errors arrive as a {"type":"error"} event on stdout (exit 1), e.g. a paid
  # model on an account with no credits.
  local oc_msg
  oc_msg="$(jq -rs '[.[]? | select(.type == "error") | (.error.data.message // .error.message // .error.name // empty)] | last // empty' \
              "$raw/stdout.json" 2>/dev/null)"
  if [ "$rc" != "0" ] || [ -n "$oc_msg" ]; then
    [ -z "$oc_msg" ] && oc_msg="$(head -c 300 "$raw/stderr.txt" 2>/dev/null)"
    [ -z "$oc_msg" ] && oc_msg="opencode exited $rc with no output on stdout or stderr"
    GOBLIN_P_ERRKIND="$(provider_classify_error "$oc_msg")"
    GOBLIN_P_ERRMSG="$(printf '%s' "$oc_msg" | head -c 300)"
    return 1
  fi

  # The answer is the text events, in order.
  jq -rs '[.[]? | select(.type == "text") | .part.text // empty] | join("")' "$raw/stdout.json" \
    > "$raw/last.txt" 2>/dev/null

  findings_extract "$raw/last.txt" "$out" && return 0
  GOBLIN_P_ERRKIND=bad_output; GOBLIN_P_ERRMSG="no JSON in response"
  return 2
}
