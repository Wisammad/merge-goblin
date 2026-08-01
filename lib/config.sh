#!/usr/bin/env bash
# config.sh — the config plane. Ported from prauto-lib.sh, same function names.

GOBLIN_CONFIG_SCHEMA_VERSION=2

# Defaults are also the migration target: cfg_backfill adds any missing key
# without ever overwriting a user's value.
goblin_default_config() {
  cat <<JSON
{
  "schemaVersion": $GOBLIN_CONFIG_SCHEMA_VERSION,
  "identity": { "githubLogin": "" },
  "enabled": true,
  "snoozeUntil": 0,
  "intervalSeconds": 300,
  "provider": "claude",
  "providers": {
    "claude": { "model": "sonnet", "bin": "" },
    "codex":  { "model": "", "reasoningEffort": "medium", "bin": "" },
    "cursor": { "model": "", "bin": "" }
  },
  "providerFallback": [],
  "timeoutSecs": 900,
  "repos": [],
  "fleet": [],
  "fleetAssignment": true,
  "takeoverGraceSecs": 2700,
  "claimTtlSecs": 3600,
  "verdictMode": "comment",
  "allowApprove": false,
  "budgetCapUsd": 10,
  "maxReviewsPerRun": 5,
  "maxFindings": 25,
  "maxDiffBytes": 400000,
  "postIntentComment": true,
  "postCommitStatus": true,
  "incrementalReview": true,
  "notify": { "started": true, "posted": true, "failed": true, "budget": true, "sound": true },
  "refsForbidden": false,
  "refsForbiddenAt": 0,
  "update": { "notify": true, "checkEverySecs": 86400 },
  "maxReviewsPerDay": 20,
  "skipIfHumanReviewed": true,
  "setupComplete": false,
  "cache": { "reposTtlSecs": 3600 }
}
JSON
}

cfg_read() { cat "$CONFIG" 2>/dev/null; }

cfg_ensure() {
  goblin_ensure_dirs
  if ! cfg_read | jq -e . >/dev/null 2>&1; then
    goblin_default_config > "$CONFIG"
  fi
}

# cfg_get <jq-filter> <default>
cfg_get() {
  local filter="$1" default="${2:-}" v
  v="$(cfg_read | jq -r "$filter" 2>/dev/null)"
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$default"; else printf '%s' "$v"; fi
}

# cfg_get_json <jq-filter> <default-json> — for arrays/objects.
cfg_get_json() {
  local filter="$1" default="${2:-null}" v
  v="$(cfg_read | jq -c "$filter" 2>/dev/null)"
  if [ -z "$v" ] || [ "$v" = "null" ]; then printf '%s' "$default"; else printf '%s' "$v"; fi
}

# cfg_set [jq-args...] <jq-assignment> — atomic read-modify-write.
# Extra jq options (--arg/--argjson) may precede the filter.
cfg_set() {
  cfg_ensure
  local out
  if out="$(cfg_read | jq "$@" 2>/dev/null)" && [ -n "$out" ]; then
    printf '%s\n' "$out" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
  else
    rm -f "$CONFIG.tmp" 2>/dev/null
    return 1
  fi
}

# Add keys introduced by a newer version without clobbering existing values.
# `*` in jq is a recursive merge where the RIGHT side wins, so defaults go left.
cfg_backfill_defaults() {
  cfg_ensure
  local merged
  merged="$(jq -s '.[0] * .[1] | .schemaVersion = '"$GOBLIN_CONFIG_SCHEMA_VERSION" \
    <(goblin_default_config) "$CONFIG" 2>/dev/null)"
  [ -n "$merged" ] && printf '%s\n' "$merged" > "$CONFIG.tmp" && mv "$CONFIG.tmp" "$CONFIG"
}

# --- repos ----------------------------------------------------------------
# Each entry: {slug, enabled, promptPath, login}
cfg_repos_enabled() {
  cfg_read | jq -r '.repos[]? | select(.enabled != false) | .slug' 2>/dev/null
}

cfg_repo_field() {  # <slug> <field> <default>
  local slug="$1" field="$2" def="${3:-}" v
  v="$(cfg_read | jq -r --arg s "$slug" --arg f "$field" \
        '.repos[]? | select(.slug == $s) | .[$f] // empty' 2>/dev/null | head -1)"
  [ -z "$v" ] && v="$def"
  printf '%s' "$v"
}

cfg_repo_add() {  # <slug>
  cfg_ensure
  cfg_set --arg s "$1" \
    'if ([.repos[]?.slug] | index($s)) then . else .repos += [{slug:$s, enabled:true, promptPath:"", login:""}] end'
}

# cfg_repo_set_field <slug> <field> <value> — the setter half of cfg_repo_field.
#
# The value is run through jq -R so "5" stores as a number and "true" as a boolean
# rather than as strings: the panel sends everything as text, and a string where a
# boolean belongs reads as truthy forever afterwards.
cfg_repo_set_field() {
  local slug="$1" field="$2" raw="$3" val
  val="$(printf '%s' "$raw" | jq -R 'tonumber? // (if . == "true" then true elif . == "false" then false else . end)')"
  cfg_set --arg s "$slug" --arg f "$field" --argjson v "$val" \
    '.repos |= map(if .slug == $s then .[$f] = $v else . end)'
}

cfg_repo_rm()     { cfg_set --arg s "$1" '.repos |= map(select(.slug != $s))'; }
cfg_repo_enable() { cfg_set --arg s "$1" --argjson e "$2" '.repos |= map(if .slug == $s then .enabled = $e else . end)'; }

# The GitHub login the Goblin reviews as. Config first, then the active gh account.
goblin_login() {
  local l; l="$(cfg_get '.identity.githubLogin' '')"
  if [ -z "$l" ]; then l="$(gh api user --jq .login 2>/dev/null)"; fi
  printf '%s' "$l"
}
