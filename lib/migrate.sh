#!/usr/bin/env bash
# migrate.sh — import state from the original single-user setup (~/conductor).
#
# Stats and the dedup ledger are the things worth keeping: losing the ledger
# would make Bob re-review, and re-post on, every open PR.

cmd_migrate() {
  local from="$HOME/conductor"
  while [ $# -gt 0 ]; do
    case "$1" in --from) from="$2"; shift 2 ;; *) shift ;; esac
  done
  cfg_ensure; goblin_ensure_dirs
  # Create the destinations up front: a redirect from a missing file is reported
  # by the shell itself, before the command's own 2>/dev/null can suppress it.
  touch "$LEDGER" "$EVENTS" 2>/dev/null

  local old_cfg="$from/prauto.config.json"
  local old_events="$from/prauto.events.jsonl"
  local old_ledger="$from/review-requested-prs.state"

  if [ ! -f "$old_cfg" ] && [ ! -f "$old_events" ] && [ ! -f "$old_ledger" ]; then
    echo "nothing to migrate from $from"; return 0
  fi
  echo "migrating from $from"

  # ledger: identical "<pr>:<headSha>" line format, so append and de-dupe.
  if [ -f "$old_ledger" ]; then
    local before after
    before="$(wc -l < "$LEDGER" 2>/dev/null | tr -d ' ')"; before="${before:-0}"
    cat "$old_ledger" "$LEDGER" 2>/dev/null | grep . | sort -u > "$LEDGER.tmp" && mv "$LEDGER.tmp" "$LEDGER"
    after="$(wc -l < "$LEDGER" | tr -d ' ')"
    echo "  ledger:  $before → $after entries (won't re-review already-reviewed commits)"
  fi

  # events: same schema; merge and sort by time so stats stay correct.
  if [ -f "$old_events" ]; then
    local n
    cat "$old_events" "$EVENTS" 2>/dev/null | grep . | jq -sc 'unique_by([.at,.number,.status]) | sort_by(.at) | .[]' \
      > "$EVENTS.tmp" 2>/dev/null && mv "$EVENTS.tmp" "$EVENTS"
    n="$(wc -l < "$EVENTS" | tr -d ' ')"
    echo "  history: $n events (\$$(today_spend) spent today, \$$(compute_stats | jq -r '.spendUsd.total | .*100|round/100') total)"
  fi

  # config: map the flat v1 keys onto the v2 shape.
  if [ -f "$old_cfg" ]; then
    local login cap enabled verdict interval
    login="$(jq -r '.reviewerLogin // ""' "$old_cfg" 2>/dev/null)"
    cap="$(jq -r '.budgetCapUsd // 10' "$old_cfg" 2>/dev/null)"
    enabled="$(jq -r '.enabled // true' "$old_cfg" 2>/dev/null)"
    verdict="$(jq -r '.verdictMode // "comment"' "$old_cfg" 2>/dev/null)"
    interval=900
    [ -n "$login" ] && cfg_set --arg l "$login" '.identity.githubLogin = $l'
    cfg_set --argjson c "${cap:-10}" '.budgetCapUsd = $c'
    cfg_set --argjson e "${enabled:-true}" '.enabled = $e'
    cfg_set --arg v "${verdict:-comment}" '.verdictMode = $v'
    cfg_set --argjson i "$interval" '.intervalSeconds = $i'
    echo "  config:  login=$login cap=\$$cap verdict=$verdict"
  fi

  # The old tool hardcoded its single repo in the engine script rather than in
  # config, so read it back out instead of assuming which repo it was.
  local old_engine="$from/review-requested-prs.sh" old_repo
  if [ -f "$old_engine" ]; then
    old_repo="$(grep -m1 -E '^REPO=' "$old_engine" 2>/dev/null | sed 's/^REPO=//; s/"//g; s/'"'"'//g')"
    if [ -n "$old_repo" ]; then cfg_repo_add "$old_repo"; echo "  repo:    $old_repo"; fi
  fi

  # The old scratch clone is multiple GB, so adopting it beats re-cloning — but
  # MOVING it out from under a still-installed old tool is destructive, and into
  # a throwaway GOBLIN_HOME it is data loss. Only adopt when this is the real
  # install and the old scheduler is already stopped; otherwise leave it and let
  # Bob clone on first use.
  local old_scratch="$from/pr-review-scratch" newdir
  newdir="$(goblin_repo_dir "${old_repo:-unknown/unknown}")"
  if [ -n "${old_repo:-}" ] && [ -d "$old_scratch/.git" ] && [ ! -e "$newdir" ]; then
    if [ "$GOBLIN_HOME" = "$HOME/.$GOBLIN_SLUG" ] \
       && ! launchctl print "gui/$(id -u)/com.kiril.review-requested-prs" >/dev/null 2>&1; then
      mv "$old_scratch" "$newdir" 2>/dev/null && echo "  clone:   adopted the existing scratch clone (saved a re-clone)"
    else
      echo "  clone:   left in place (old setup still installed) — Bob will clone its own"
    fi
  fi

  touch "$GOBLIN_HOME/.migrated"
  status_set '{}'
  echo
  echo "done. the old setup is untouched — disable it with:"
  echo "  launchctl bootout gui/\$(id -u)/com.kiril.review-requested-prs 2>/dev/null"
  echo "  launchctl disable gui/\$(id -u)/com.kiril.review-requested-prs"
}
