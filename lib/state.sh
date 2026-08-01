#!/usr/bin/env bash
# state.sh — status snapshot, event ledger, derived stats, UI state cache.
# Ported from prauto-lib.sh; same function names so behaviour is preserved.

STATS_EMPTY='{"reviews":{"today":0,"week":0,"total":0},"spendUsd":{"today":0,"week":0,"total":0},"lastReview":{"number":0,"title":"","url":"","at":0},"recentFailures":[]}'

# Stats derived from the append-only ledger, so they survive any status.json loss.
# NOTE: read the file into a variable first — piping `cat` of a missing file
# under `set -o pipefail` fails the pipeline and would fire the fallback ON TOP
# of valid output, emitting two JSON objects (a real bug we already hit once).
compute_stats() {
  local mid wk day data out
  mid="$(midnight_epoch)"; wk="$(week_ago_epoch)"
  # A rolling 24 hours, not midnight: a failure at 23:50 must not stop counting
  # as recent ten minutes later.
  day="$(( $(now_epoch) - 86400 ))"
  data="$(cat "$EVENTS" 2>/dev/null || true)"
  out="$(printf '%s' "$data" | jq -s --argjson mid "$mid" --argjson wk "$wk" --argjson day "$day" '
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
      # Two bounds, because this list drives the red glyph in the menu bar and an
      # unbounded "last 3 failures ever" means one bad afternoon marks the icon
      # broken permanently — which trains people to ignore it, at which point it
      # protects nobody. (No apostrophes in here: the whole jq program is a
      # single-quoted shell string, and one would end it.)
      #   * older than a day is history, not a fault
      #   * a failure the same PR later recovered from is not a fault either; a
      #     transient blip that the next poll fixed must not keep accusing.
      recentFailures: (
        ([.[] | select(.status=="posted")]) as $ok
        | [ .[]
            | select(.status=="failed")
            | select((.at // 0) >= $day)
            | . as $f
            | select(([ $ok[]
                        | select(((.number // 0) == ($f.number // 0))
                                 and ((.repo // "") == ($f.repo // ""))
                                 and ((.at // 0) > ($f.at // 0))) ] | length) == 0)
            | {number:(.number//0), reason:(.reason//""), at:(.at//0)} ]
        | reverse | .[0:3]
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

# Is this install actually set up? DERIVED, not just read from the flag.
#
# `.setupComplete` is written by the wizard, so every install that predates the
# wizard has it false while being perfectly well configured — and the menu bar
# turns that into a red "not set up" icon on a machine that has been reviewing
# happily for weeks. An install with a login and at least one repo IS set up,
# whatever the flag says; the flag can only add to that, never take it away.
ui_setup_complete() {
  [ "$(cfg_get '.setupComplete' false)" = "true" ] && { printf 'true'; return 0; }
  local login repos
  login="$(cfg_get '.identity.githubLogin' '')"
  repos="$(cfg_get_json '[.repos[]?] | length' '0')"
  if [ -n "$login" ] && [ "${repos:-0}" -gt 0 ] 2>/dev/null; then
    printf 'true'
  else
    printf 'false'
  fi
}
# One precomputed blob the control panel reads, so the UI never has to shell out
# per field. Refreshed by every writer.
ui_state_write() {
  local st stats running disabled installed inbox stuck now interval update
  st="$(cat "$STATUS" 2>/dev/null)"
  printf '%s' "$st" | jq -e . >/dev/null 2>&1 || st='{}'
  stats="$(compute_stats)"
  running=false;   agent_running   >/dev/null 2>&1 && running=true
  disabled=false;  agent_disabled  >/dev/null 2>&1 && disabled=true
  installed=false; agent_installed >/dev/null 2>&1 && installed=true
  now="$(now_epoch)"
  interval="$(cfg_get '.intervalSeconds' 900)"
  # Read the cached update check; never perform one. This runs on every status
  # write, including interactive ones, and must stay free of network calls.
  update="$(cat "$UPDATE_STATE" 2>/dev/null)"
  printf '%s' "$update" | jq -e . >/dev/null 2>&1 || update='{}'

  inbox='{"waiting":0,"mine":0,"at":0,"stale":true}'
  if [ -f "$INBOX" ]; then
    inbox="$(inbox_read | jq -c --argjson now "$now" --argjson iv "${interval:-900}" '
      { waiting: (.counts.waiting // 0),
        mine:    (.counts.mine // 0),
        at:      (.at // 0),
        # A number nobody has refreshed for three intervals is not "0 waiting",
        # it is "we do not know" — and the bar dims it rather than lying.
        stale:   (((.at // 0) == 0) or (($now - (.at // 0)) > ($iv * 3))) }' 2>/dev/null)"
    [ -z "$inbox" ] && inbox='{"waiting":0,"mine":0,"at":0,"stale":true}'
  fi
  stuck="$(attempt_stuck_json 2>/dev/null)"; [ -z "$stuck" ] && stuck='[]'

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
    --argjson setup "$(ui_setup_complete)" \
    --argjson repos "$(cfg_get_json '[.repos[]? | {slug, enabled: (.enabled != false)}]' '[]')" \
    --argjson fleet "$(cfg_get_json '.fleet' '[]')" \
    --argjson inbox "$inbox" \
    --argjson stuck "$stuck" \
    --argjson settings "$(cfg_get_json '{
        verdictMode, allowApprove, budgetCapUsd, maxReviewsPerDay, maxReviewsPerRun,
        maxFindings, intervalSeconds, timeoutSecs, maxDiffBytes, incrementalReview,
        postCommitStatus, postIntentComment, fleetAssignment, skipIfHumanReviewed,
        notify,
        providers: (.providers | with_entries(.value |= {model}))
      }' '{}')" \
    --argjson running "$running" --argjson disabled "$disabled" \
    --argjson installed "$installed" \
    --argjson update "$update" \
    --argjson checkedAt "$now" '
    . + $stats + {
      goblin: {name: $name, version: $version},
      update: {
        # Re-derive against the running version: a stale "available" left over
        # from before an upgrade must not keep nagging afterwards.
        available: (($update.available // false) and (($update.latest // "") != $version)),
        latest: ($update.latest // ""), checkedAt: ($update.checkedAt // 0),
        url: ($update.url // "")
      },
      provider: {id: $provider, model: $model},
      identity: {login: $login, ghActive: $ghActive, ok: ($login == "" or $login == $ghActive)},
      budgetCapUsd: $cap, snoozeUntil: $snoozeUntil, enabled: $enabled,
      setup: {complete: $setup},
      # Every editable setting, flattened alongside the runtime state. Without this
      # the panel can only show its own build defaults for verdict, limits, schedule
      # and notifications — which is worse than showing nothing, because a default
      # presented as a live value invites you to "fix" what is already correct.
      # Providers are reduced to models only: no `bin` ever reaches the UI, because
      # a UI that can display a binary path is one patch away from editing it.
      settings: $settings,
      repos: $repos,
      fleet: $fleet,
      inbox: $inbox,
      stuck: $stuck,
      agent: {running: $running, disabled: $disabled, installed: $installed, checkedAt: $checkedAt}
    }
    # The menu bar glyph is decided HERE, in bash, not in Swift. Swift is then a
    # pure name -> image lookup, which means "when does the icon claim something is
    # broken" is asserted by the offline test suite instead of living in code that
    # has no tests at all.
    #
    # error fires only for things that are genuinely broken. Off, snoozed, paused
    # and quota each get their own glyph: conflating a deliberate pause with a fault
    # is the fastest way to teach someone to ignore the icon.
    | . as $s
    # NOTE on `//`: that is the jq ALTERNATIVE operator, not null-coalescing. It
    # takes the right-hand side when the left is null OR FALSE, so
    # `(.identity.ok // true)` would turn a genuine `false` into `true` — silently
    # disabling the wrong-account warning, which is the one failure mode that has
    # broken this tool repeatedly. Booleans use an explicit null test instead, and
    # `//` is reserved for numbers, strings and objects.
    | ($s.doctor.fail // 0) as $dfail
    | ((if $s.identity.ok == null then true else $s.identity.ok end) | not) as $idbad
    # Only a fault if a schedule was actually installed: otherwise this is just a
    # machine where the agent has not been set up, which doctor already reports.
    | (($s.agent.installed == true) and ($s.agent.disabled == false)
       and ($s.agent.running == false)) as $notloaded
    | (($s.recentFailures // []) | length >= 2) as $failing
    | (($s.stuck // []) | length > 0) as $anystuck
    | ($idbad or ($dfail > 0) or $notloaded or $failing or $anystuck) as $err
    | .bar = {
        glyph: (
          if ($s.setup.complete | not) then "error"
          elif ($s.agent.disabled or ($s.enabled | not)) then "off"
          elif $s.state == "reviewing" then "reviewing"
          elif $err then "error"
          elif $s.state == "snoozed" then "snoozed"
          elif $s.pausedReason == "quota" then "quota"
          elif $s.state == "paused" then "paused"
          else "idle" end),
        count: ($s.inbox.waiting // 0),
        stale: (if $s.inbox.stale == null then true else $s.inbox.stale end),
        tooltip: (
          if ($s.setup.complete | not) then "not set up yet"
          elif ($s.agent.disabled or ($s.enabled | not)) then "off"
          elif $s.state == "reviewing" then ($s.activity // "reviewing")
          elif $idbad then "wrong GitHub account"
          elif $notloaded then "scheduler is not loaded"
          elif ($dfail > 0) then "\($dfail) health check(s) failing"
          elif $anystuck then "\($s.stuck | length) PR(s) stuck"
          elif $failing then "recent reviews are failing"
          elif $s.state == "snoozed" then "snoozed"
          elif $s.pausedReason == "quota" then "daily cap reached"
          elif $s.state == "paused" then "paused"
          else "idle — \($s.inbox.waiting // 0) waiting" end)
      }' 2>/dev/null | atomic_write "$UISTATE" || true
}
