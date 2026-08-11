#!/usr/bin/env bash
# inbox.sh — what is waiting on the team, and the number on the menu bar icon.
#
# The engine already fetched exactly this list on every run and then threw it
# away: gh_prs listed the open PRs, engine_repo iterated them, and the file was
# deleted. That list *is* the count the menu bar needs, so publishing it costs
# ZERO extra API calls on the scheduled path.
#
# `reviewed` is derived from the LOCAL ledger only, never from gh_prior_review —
# that is a network call per PR, and this has to be cheap enough to run on every
# cycle. The consequence is honest: a PR a teammate reviewed shows as
# `assigned_elsewhere`, not `reviewed`, which is the right answer for a bar that
# says "waiting on the team".

INBOX_SCHEMA_VERSION=1

# inbox_classify <entry-json> <my-login> <eligible-newline-list> <assignee>
#
# A pure function of its arguments plus the ledger and attempts files. Kept pure
# on purpose: it is the single most valuable thing in here to test offline, and
# every gate in engine_pr defers to it.
#
# States, in the order they are decided:
#   draft               — not ready, never counted
#   not_ours            — nobody the goblin fleet covers was asked to review
#   reviewed            — this exact commit is in our ledger
#   reviewed_by_other   — a teammate already reviewed it; not ours to touch
#   blocked             — failed too often / waiting out a backoff
#   assigned_elsewhere  — a live teammate owns this one
#   waiting             — ours, and not yet done
#
# Only `waiting` is ever shown as awaiting review. Everything else is a count.
inbox_classify() {
  local entry="$1" me="$2" eligible="$3" assignee="$4" human_reviewers="${5:-}"
  local pr head draft state mine=false reason=""

  pr="$(printf '%s' "$entry"   | jq -r '.number')"
  head="$(printf '%s' "$entry" | jq -r '.head')"
  draft="$(printf '%s' "$entry" | jq -r '.draft')"

  [ "$assignee" = "$me" ] && mine=true

  if [ "$draft" = "true" ]; then
    state=draft
  elif [ -z "$eligible" ]; then
    state=not_ours
  elif ledger_reviewed "${INBOX_REPO:-}" "$pr" "$head"; then
    state=reviewed
  elif [ -n "$human_reviewers" ]; then
    # Checked before the backoff and assignment states on purpose: "a person has
    # this" outranks every internal reason we might have had for skipping it.
    state=reviewed_by_other
    reason="reviewed by $human_reviewers"
  elif attempt_blocked "$(attempt_key "${INBOX_REPO:-}" "$pr" "$head")"; then
    state=blocked
    reason="$(attempt_reason "$(attempt_key "${INBOX_REPO:-}" "$pr" "$head")")"
  elif [ "$mine" != true ]; then
    state=assigned_elsewhere
  else
    state=waiting
  fi

  jq -nc \
    --argjson pr "${pr:-0}" \
    --arg repo "${INBOX_REPO:-}" \
    --arg head "$head" \
    --arg title "$(printf '%s' "$entry" | jq -r '.title // ""' | tr -d '\000-\037' | cut -c 1-140)" \
    --arg url "$(printf '%s' "$entry" | jq -r '.url // ""')" \
    --arg author "$(printf '%s' "$entry" | jq -r '.author // ""')" \
    --argjson updatedAt "$(printf '%s' "$entry" | jq -r '.updatedAt // 0')" \
    --arg state "$state" \
    --arg assignee "$assignee" \
    --argjson mine "$mine" \
    --arg reason "$reason" \
    '{number:$pr, repo:$repo, head:$head, title:$title, url:$url, author:$author,
      updatedAt:$updatedAt, state:$state, assignee:$assignee, mine:$mine, reason:$reason}'
}

# inbox_write <rows-file>
# Written once at the end of a run, never mid-loop: a crash halfway through must
# not publish a half inbox that reads as "nothing is waiting".
inbox_write() {
  local rows="${1:-/dev/null}"
  local now; now="$(now_epoch)"
  jq -s -c --argjson at "$now" --argjson v "$INBOX_SCHEMA_VERSION" '
    # A PR can be written twice in one run: classified early from free signals, then
    # corrected once a network answer arrives (a teammate had already reviewed it).
    # Last write wins, so the corrected row is the one that survives.
    ( group_by(.repo + "#" + (.number | tostring)) | map(last) ) as $rows
    | { schemaVersion: $v,
        at: $at,
        stale: false,
        counts: {
          waiting:            ([$rows[] | select(.state=="waiting")]            | length),
          mine:               ([$rows[] | select(.state=="waiting" and .mine)]  | length),
          assignedElsewhere:  ([$rows[] | select(.state=="assigned_elsewhere")] | length),
          blocked:            ([$rows[] | select(.state=="blocked")]            | length),
          reviewed:           ([$rows[] | select(.state=="reviewed")]           | length),
          reviewedByOther:    ([$rows[] | select(.state=="reviewed_by_other")]  | length),
          drafts:             ([$rows[] | select(.state=="draft")]              | length),
          notOurs:            ([$rows[] | select(.state=="not_ours")]           | length)
        },
        # ONLY genuinely-awaiting PRs. This list is the answer to "what is waiting
        # on the team", so a draft, something a teammate already reviewed, or
        # something we already did does not belong in it — and `counts.waiting`
        # above is by construction the length of this array.
        prs: [ $rows[] | select(.state=="waiting") ],
        # Everything else, kept for the summary line rather than thrown away.
        other: [ $rows[] | select(.state!="waiting" and .state!="not_ours")
                 | {number, repo, state, reason} ]
      }' "$rows" 2>/dev/null | atomic_write "$INBOX" || true
}

inbox_read() {
  local d; d="$(cat "$INBOX" 2>/dev/null)"
  printf '%s' "$d" | jq -e . >/dev/null 2>&1 && printf '%s' "$d" \
    || printf '{"schemaVersion":%s,"at":0,"stale":true,"counts":{"waiting":0,"mine":0},"prs":[]}' \
         "$INBOX_SCHEMA_VERSION"
}

# The bar must be able to refresh its number while the engine is paused, snoozed,
# off, or over quota — otherwise "3 waiting" freezes the moment you pause, which
# is exactly when you look at it. This is the listing pass only: one gh call per
# repo, no checkout, no model, no cost.
cmd_inbox() {
  local as_json=false refresh=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)    as_json=true; shift ;;
      --refresh) refresh=true; shift ;;
      *) shift ;;
    esac
  done

  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs

  if [ "$refresh" = true ]; then
    # Rate limit: the panel polls, and gh_prs is a real API call per repo.
    local last age
    last="$(inbox_read | jq -r '.at // 0')"
    age=$(( $(now_epoch) - ${last:-0} ))
    if [ "$age" -ge 60 ]; then
      inbox_refresh || true
    fi
  fi

  if [ "$as_json" = true ]; then inbox_read; return 0; fi

  inbox_read | jq -r '
    "  \(.counts.waiting) waiting · \(.counts.mine) yours\n",
    (.prs[] | "  \(.state | .[0:18] | . + (" " * (19 - length)))#\(.number)  \(.title)")'
}

inbox_refresh() {
  . "$LIB_DIR/github.sh"; . "$LIB_DIR/claim.sh"
  engine_auth_lite >/dev/null 2>&1 || { log "inbox: not authenticated"; return 1; }

  local rows="$RUNTMP/inbox-rows-$$.json"; : > "$rows"
  local slug prs n i entry eligible assignee
  for slug in $(cfg_repos_enabled); do
    prs="$RUNTMP/inbox-prs-$$.json"
    gh_prs "$slug" "$prs" || continue
    INBOX_REPO="$slug"
    n="$(jq 'length' "$prs" 2>/dev/null || echo 0)"
    i=0
    while [ "$i" -lt "${n:-0}" ]; do
      entry="$(jq -c --argjson i "$i" '.[$i]' "$prs")"; i=$((i + 1))
      eligible="$(claim_eligible "$entry" "$slug")"
      assignee=""
      [ -n "$eligible" ] && assignee="$(claim_assignee "$(printf '%s' "$entry" | jq -r '.number')" \
                                        "$(printf '%s' "$entry" | jq -r '.head')" "$eligible")"

      # Classify from free signals first, then spend an API call ONLY on the PRs
      # that would otherwise be listed as awaiting review. Without this the bar
      # keeps showing PRs a teammate already reviewed for as long as the engine is
      # off — and "the engine is off" is exactly when someone stares at the bar.
      # Bounded by the number of genuinely-waiting PRs, which is normally a handful.
      local row humans pr_n
      row="$(inbox_classify "$entry" "$GOBLIN_LOGIN" "$eligible" "$assignee")"
      if [ "$(printf '%s' "$row" | jq -r '.state')" = "waiting" ] \
         && [ "$(cfg_get '.skipIfHumanReviewed' true)" = "true" ]; then
        pr_n="$(printf '%s' "$entry" | jq -r '.number')"
        local rj="$RUNTMP/inbox-reviews-$$.json"
        if gh_reviews_fetch "$slug" "$pr_n" "$rj"; then
          humans="$(gh_human_reviewers "$rj" | paste -sd, - 2>/dev/null)"
          [ -n "$humans" ] && row="$(printf '%s' "$row" | jq -c --arg h "$humans" \
            '.state = "reviewed_by_other" | .reason = ("reviewed by " + $h)')"
        fi
        rm -f "$rj" 2>/dev/null
      fi
      printf '%s\n' "$row" >> "$rows"
    done
    rm -f "$prs" 2>/dev/null
  done
  inbox_write "$rows"
  rm -f "$rows" 2>/dev/null
  status_set '{}'
}
