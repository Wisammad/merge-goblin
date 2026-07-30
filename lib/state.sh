#!/usr/bin/env bash
# state.sh — status snapshot, event ledger, derived stats, UI state cache.
# Ported from prauto-lib.sh; same function names so behaviour is preserved.

STATS_EMPTY='{"reviews":{"today":0,"week":0,"total":0},"spendUsd":{"today":0,"week":0,"total":0},"lastReview":{"number":0,"title":"","url":"","at":0},"recentFailures":[]}'

# Stats derived from the append-only ledger, so they survive any status.json loss.
# NOTE: read the file into a variable first — piping `cat` of a missing file
# under `set -o pipefail` fails the pipeline and would fire the fallback ON TOP
# of valid output, emitting two JSON objects (a real bug we already hit once).
compute_stats() {
  local mid wk data out
  mid="$(midnight_epoch)"; wk="$(week_ago_epoch)"
  data="$(cat "$EVENTS" 2>/dev/null || true)"
  out="$(printf '%s' "$data" | jq -s --argjson mid "$mid" --argjson wk "$wk" '
    {
      reviews: {
        today: ([.[] | select(.status=="posted" and .at>=$mid)] | length),
        week:  ([.[] | select(.status=="posted" and .at>=$wk)]  | length),
        total: ([.[] | select(.status=="posted")]               | length)
      },
      spendUsd: {
        today: ([.[] | select(.at>=$mid) | (.costUsd // 0)] | add // 0),
        week:  ([.[] | select(.at>=$wk)  | (.costUsd // 0)] | add // 0),
        total: ([.[] |                     (.costUsd // 0)] | add // 0)
      },
      lastReview: (
        ([.[] | select(.status=="posted")] | last // {number:0,title:"",url:"",at:0})
        | {number:(.number//0), title:(.title//""), url:(.url//""), at:(.at//0)}
      ),
      recentFailures: (
        [.[] | select(.status=="failed")] | reverse | .[0:3]
        | map({number:(.number//0), reason:(.reason//""), at:(.at//0)})
      )
    }' 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '%s' "$STATS_EMPTY"; fi
}

today_spend() {
  local mid data out
  mid="$(midnight_epoch)"
  data="$(cat "$EVENTS" 2>/dev/null || true)"
  out="$(printf '%s' "$data" | jq -s --argjson mid "$mid" \
    '[.[] | select(.at>=$mid) | (.costUsd // 0)] | add // 0' 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '0'; fi
}

today_review_count() {
  local mid data out
  mid="$(midnight_epoch)"
  data="$(cat "$EVENTS" 2>/dev/null || true)"
  out="$(printf '%s' "$data" | jq -s --argjson mid "$mid" \
    '[.[] | select(.status=="posted" and .at>=$mid)] | length' 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '0'; fi
}

# status_set '<json patch>' — merge patch over current status, refresh stats,
# write atomically, then refresh the UI state cache.
status_set() {
  local patch="${1:-\{\}}" cur stats
  goblin_ensure_dirs
  cur="$(cat "$STATUS" 2>/dev/null)"
  if ! printf '%s' "$cur" | jq -e . >/dev/null 2>&1; then
    cur='{"schemaVersion":1,"state":"idle","pausedReason":"","activity":"","lastRunStarted":0,"lastRunFinished":0,"nextRunEstimate":0}'
  fi
  stats="$(compute_stats)"
  if printf '%s' "$cur" | jq --argjson patch "$patch" --argjson stats "$stats" \
       '. + $patch + $stats | .schemaVersion = 1' > "$STATUS.tmp" 2>/dev/null; then
    mv "$STATUS.tmp" "$STATUS"
    ui_state_write
  else
    rm -f "$STATUS.tmp" 2>/dev/null
  fi
}

# events_append <status> <number> <title> <url> <cost> <reason> [repo] [provider] [model]
events_append() {
  local evstatus="$1" number="$2" title="$3" url="$4" cost="${5:-0}" reason="${6:-}"
  local repo="${7:-}" provider="${8:-}" model="${9:-}"
  goblin_ensure_dirs
  jq -nc --arg st "$evstatus" --argjson n "${number:-0}" --arg t "$title" \
     --arg u "$url" --argjson c "${cost:-0}" --arg r "$reason" \
     --arg repo "$repo" --arg p "$provider" --arg m "$model" \
     --argjson at "$(now_epoch)" \
     '{at:$at, number:$n, title:$t, url:$u, costUsd:$c, status:$st, reason:$r,
       repo:$repo, provider:$p, model:$m}' >> "$EVENTS" 2>/dev/null || true
}

ledger_has()  { grep -qxF "$1" "$LEDGER" 2>/dev/null; }
ledger_add()  { goblin_ensure_dirs; printf '%s\n' "$1" >> "$LEDGER" 2>/dev/null || true; }

# --- UI state cache --------------------------------------------------------
# One precomputed blob the control panel reads, so the UI never has to shell out
# per field. Refreshed by every writer.
ui_state_write() {
  local st stats running disabled
  st="$(cat "$STATUS" 2>/dev/null)"
  printf '%s' "$st" | jq -e . >/dev/null 2>&1 || st='{}'
  stats="$(compute_stats)"
  running=false; agent_running  >/dev/null 2>&1 && running=true
  disabled=false; agent_disabled >/dev/null 2>&1 && disabled=true

  printf '%s' "$st" | jq \
    --argjson stats "$stats" \
    --arg name "$GOBLIN_NAME" \
    --arg version "$GOBLIN_VERSION" \
    --arg provider "$(cfg_get '.provider' 'claude')" \
    --arg model "$(cfg_get ".providers.$(cfg_get '.provider' 'claude').model" '')" \
    --arg login "$(cfg_get '.identity.githubLogin' '')" \
    --arg ghActive "$(gh_active_account)" \
    --argjson cap "$(cfg_get '.budgetCapUsd' 0)" \
    --argjson snoozeUntil "$(cfg_get '.snoozeUntil' 0)" \
    --argjson enabled "$(cfg_get '.enabled' true)" \
    --argjson repos "$(cfg_get_json '[.repos[]? | {slug, enabled: (.enabled != false)}]' '[]')" \
    --argjson running "$running" --argjson disabled "$disabled" \
    --argjson checkedAt "$(now_epoch)" '
    . + $stats + {
      goblin: {name: $name, version: $version},
      provider: {id: $provider, model: $model},
      identity: {login: $login, ghActive: $ghActive, ok: ($login == "" or $login == $ghActive)},
      budgetCapUsd: $cap, snoozeUntil: $snoozeUntil, enabled: $enabled,
      repos: $repos,
      agent: {running: $running, disabled: $disabled, checkedAt: $checkedAt}
    }' > "$UISTATE.tmp" 2>/dev/null && mv "$UISTATE.tmp" "$UISTATE" || rm -f "$UISTATE.tmp" 2>/dev/null
}
