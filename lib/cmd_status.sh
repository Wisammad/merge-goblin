#!/usr/bin/env bash
# cmd_status.sh — human-readable state summary.

cmd_status() {
  cfg_ensure
  if [ "${1:-}" = "--json" ]; then
    ui_state_write
    cat "$UISTATE" 2>/dev/null || echo '{}'
    return 0
  fi

  ui_state_write
  local m; m="$(cat "$UISTATE" 2>/dev/null)"
  printf '%s' "$m" | jq -e . >/dev/null 2>&1 || m='{}'

  local state reason activity
  state="$(printf '%s' "$m"    | jq -r '.state // "idle"')"
  reason="$(printf '%s' "$m"   | jq -r '.pausedReason // ""')"
  activity="$(printf '%s' "$m" | jq -r '.activity // ""')"
  agent_disabled && { state="disabled"; reason="manual"; }

  local glyph
  case "$state" in
    reviewing) glyph="🔄" ;; snoozed) glyph="😴" ;;
    paused)    [ "$reason" = "budget" ] && glyph="💸" || glyph="⏸" ;;
    disabled)  glyph="⚪" ;; *) glyph="🟢" ;;
  esac

  echo "$glyph $GOBLIN_NAME v$GOBLIN_VERSION — $state${reason:+ ($reason)}"
  [ -n "$activity" ] && echo "   $activity"
  echo
  printf '   provider   %s / %s\n' \
    "$(printf '%s' "$m" | jq -r '.provider.id // "?"')" \
    "$(printf '%s' "$m" | jq -r 'if (.provider.model // "") == "" then "default" else .provider.model end')"

  local login active ok
  login="$(printf '%s' "$m"  | jq -r '.identity.login // ""')"
  active="$(printf '%s' "$m" | jq -r '.identity.ghActive // ""')"
  ok="$(printf '%s' "$m"     | jq -r '.identity.ok')"
  if [ "$ok" = "true" ]; then
    printf '   github     %s\n' "${login:-$active}"
  else
    printf '   github     %s  ⚠️  active gh account is %s — run: %s fix-account\n' "$login" "$active" "$GOBLIN_SLUG"
  fi

  # --arg, not shell interpolation: splicing $GOBLIN_SLUG into the jq program itself
  # terminates its string literal and the whole filter fails to compile.
  printf '   repos      %s\n' "$(printf '%s' "$m" | jq -r --arg cli "$GOBLIN_SLUG" \
    '[.repos[]? | select(.enabled) | .slug] | if length == 0 then "(none — \($cli) repos add owner/name)" else join(", ") end')"
  printf '   agent      %s\n' "$(printf '%s' "$m" | jq -r 'if .agent.disabled then "off (persistent)" elif .agent.running then "scheduled" else "not loaded" end')"
  echo
  printf '   today      %s reviews · $%s\n' "$(printf '%s' "$m" | jq -r '.reviews.today')" "$(printf '%s' "$m" | jq -r '.spendUsd.today | .*100|round/100')"
  printf '   week       %s reviews · $%s\n' "$(printf '%s' "$m" | jq -r '.reviews.week')"  "$(printf '%s' "$m" | jq -r '.spendUsd.week  | .*100|round/100')"
  printf '   total      %s reviews · $%s\n' "$(printf '%s' "$m" | jq -r '.reviews.total')" "$(printf '%s' "$m" | jq -r '.spendUsd.total | .*100|round/100')"
  local cap; cap="$(printf '%s' "$m" | jq -r '.budgetCapUsd')"
  [ "$cap" != "0" ] && printf '   cap        $%s/day\n' "$cap"

  local lastn; lastn="$(printf '%s' "$m" | jq -r '.lastReview.number // 0')"
  if [ "$lastn" != "0" ]; then
    echo
    printf '   last       #%s %s\n' "$lastn" "$(printf '%s' "$m" | jq -r '.lastReview.title')"
    printf '              %s\n' "$(printf '%s' "$m" | jq -r '.lastReview.url')"
  fi
  local nf; nf="$(printf '%s' "$m" | jq -r '.recentFailures | length')"
  if [ "${nf:-0}" -gt 0 ] 2>/dev/null; then
    echo
    echo "   recent failures"
    printf '%s' "$m" | jq -r '.recentFailures[] | "              #\(.number) \(.reason)"'
  fi
}
