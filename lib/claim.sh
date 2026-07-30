#!/usr/bin/env bash
# claim.sh — make sure exactly one teammate's Goblin reviews a given PR.
#
# Two layers:
#   1. deterministic assignment — free, no API calls, spreads work across the
#      fleet so everyone's subscription carries a share
#   2. a git ref as an atomic lock — authoritative, because assignment is only
#      as good as everyone's fleet config agreeing
#
# Creating a git ref is a real server-side test-and-set: exactly one concurrent
# creator gets 201, the rest get 409/422. Refs outside refs/heads/* don't appear
# in the branch list, so this is invisible to the team.

CLAIM_REF=""; CLAIM_SLUG=""; CLAIM_PR=""; CLAIM_HEAD=""

claim_ref_name()  { printf 'refs/%s/claim/pr-%s/%s' "$GOBLIN_SLUG" "$1" "$2"; }
claim_meta_glob() { printf '%s/meta/pr-%s/%s' "$GOBLIN_SLUG" "$1" "$2"; }

# Which fleet member owns this PR. Hashing on pr:headSha (not lowest login)
# spreads load evenly and re-rolls on each push so re-reviews rebalance too.
claim_assignee() {
  local pr="$1" head="$2" eligible="$3" n idx h
  # NOT `grep -c . || echo 0`: grep prints "0" AND exits 1 on no match, so the
  # fallback would append a second line and the arithmetic below dies on "0\n0".
  n="$(printf '%s\n' "$eligible" | grep -c . 2>/dev/null)"
  n="$(printf '%s' "${n:-0}" | tr -dc '0-9')"
  [ "${n:-0}" -eq 0 ] 2>/dev/null && return 1
  [ -z "$n" ] && return 1
  h="$(goblin_hash "$pr:$head" | tr -cd '0-9a-f' | cut -c1-6)"
  idx=$(( 0x$h % n + 1 ))
  printf '%s\n' "$eligible" | sort | sed -n "${idx}p"
}

# claim_eligible <pr.json-entry> — fleet ∩ requested reviewers, minus the author.
claim_eligible() {
  local entry="$1" fleet me author out="" k kind
  me="$GOBLIN_LOGIN"
  author="$(printf '%s' "$entry" | jq -r '.author // ""')"
  fleet="$(cfg_read | jq -r '.fleet[]?' 2>/dev/null)"
  [ -z "$fleet" ] && fleet="$me"

  local reqs; reqs="$(printf '%s' "$entry" | jq -c '.requested[]?' 2>/dev/null)"
  local expanded=""
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    kind="$(printf '%s' "$r" | jq -r '.kind')"
    k="$(printf '%s' "$r" | jq -r '.key')"
    if [ "$kind" = "team" ]; then
      expanded="$expanded
$(gh_team_members "$k" 2>/dev/null)"
    else
      expanded="$expanded
$k"
    fi
  done <<EOF
$reqs
EOF

  # keep only fleet members who were actually asked, never the author
  local login
  while IFS= read -r login; do
    [ -z "$login" ] && continue
    [ "$login" = "$author" ] && continue
    if printf '%s\n' "$expanded" | grep -qxF "$login"; then out="$out$login
"; fi
  done <<EOF
$fleet
EOF
  printf '%s' "$out" | grep . | sort -u
}

# claim_try <slug> <pr> <head> -> 0 won · 1 lost · 2 refs forbidden (use fallback)
claim_try() {
  local slug="$1" pr="$2" head="$3" ref code
  ref="$(claim_ref_name "$pr" "$head")"

  code="$(gh api -X POST "repos/$slug/git/refs" -f ref="$ref" -f sha="$head" \
            --include --silent 2>/dev/null | head -1 | awk '{print $2}')"

  case "$code" in
    201)
      CLAIM_REF="$ref"; CLAIM_SLUG="$slug"; CLAIM_PR="$pr"; CLAIM_HEAD="$head"
      # A ref carries no timestamp, so record one alongside it. Without this a
      # crashed run's lock could never be told apart from a live one.
      gh api -X POST "repos/$slug/git/refs" \
        -f ref="refs/$(claim_meta_glob "$pr" "$head")/$(now_epoch)-$GOBLIN_LOGIN" \
        -f sha="$head" --silent >/dev/null 2>&1 || true
      return 0 ;;
    403|404)
      log "  refs not permitted here (HTTP $code) — falling back to comment claims"
      cfg_set ".refsForbidden=true | .refsForbiddenAt=$(now_epoch)"
      return 2 ;;
    409|422)
      claim_reclaim_if_stale "$slug" "$pr" "$head" && return 0
      return 1 ;;
    *)
      # Network/5xx: fail safe. A missed cycle costs 15 minutes; a double review
      # costs the team's trust.
      return 1 ;;
  esac
}

# If the holder crashed, take over. Never loops: one retry at most.
claim_reclaim_if_stale() {
  local slug="$1" pr="$2" head="$3" ttl oldest now
  ttl="$(cfg_get '.claimTtlSecs' 3600)"
  now="$(now_epoch)"
  oldest="$(gh api "repos/$slug/git/matching-refs/$(claim_meta_glob "$pr" "$head")" \
    --jq '[.[].ref | split("/")[-1] | split("-")[0] | tonumber?] | min // empty' 2>/dev/null)"

  if [ -z "$oldest" ]; then
    # Claimed but no timestamp yet: either the winner is milliseconds from
    # writing one, or it died in between. Adopt — start the clock without
    # stealing — and let the next poll decide.
    gh api -X POST "repos/$slug/git/refs" \
      -f ref="refs/$(claim_meta_glob "$pr" "$head")/${now}-${GOBLIN_LOGIN}.adopted" \
      -f sha="$head" --silent >/dev/null 2>&1 || true
    return 1
  fi

  [ "$(( now - oldest ))" -le "${ttl:-3600}" ] && return 1

  log "  claim on #$pr is stale ($(( (now - oldest) / 60 ))m) — reclaiming"
  claim_delete_ref "$slug" "$(claim_ref_name "$pr" "$head")"
  claim_delete_meta "$slug" "$pr" "$head"
  local code
  code="$(gh api -X POST "repos/$slug/git/refs" -f ref="$(claim_ref_name "$pr" "$head")" \
            -f sha="$head" --include --silent 2>/dev/null | head -1 | awk '{print $2}')"
  if [ "$code" = "201" ]; then
    CLAIM_REF="$(claim_ref_name "$pr" "$head")"; CLAIM_SLUG="$slug"; CLAIM_PR="$pr"; CLAIM_HEAD="$head"
    gh api -X POST "repos/$slug/git/refs" \
      -f ref="refs/$(claim_meta_glob "$pr" "$head")/${now}-${GOBLIN_LOGIN}" -f sha="$head" \
      --silent >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

claim_delete_ref()  { gh api -X DELETE "repos/$1/git/refs/${2#refs/}" --silent >/dev/null 2>&1 || true; }
claim_delete_meta() {
  gh api "repos/$1/git/matching-refs/$(claim_meta_glob "$2" "$3")" --jq '.[].ref' 2>/dev/null \
    | while IFS= read -r r; do [ -n "$r" ] && claim_delete_ref "$1" "$r"; done
}

# Release on EVERY exit path. The ref is a pure mutex, never the record of what
# was reviewed — that lives in the review marker — so releasing is always safe
# and a crash can always be recovered from.
claim_release() {
  [ -n "$CLAIM_REF" ] || return 0
  claim_delete_ref "$CLAIM_SLUG" "$CLAIM_REF"
  claim_delete_meta "$CLAIM_SLUG" "$CLAIM_PR" "$CLAIM_HEAD"
  CLAIM_REF=""
}

# Drop claims left behind for commits that have since been superseded.
claim_sweep() {
  local slug="$1" pr="$2" head="$3"
  gh api "repos/$slug/git/matching-refs/$GOBLIN_SLUG/claim/pr-$pr" --jq '.[].ref' 2>/dev/null \
    | grep -v "/${head}$" \
    | while IFS= read -r r; do [ -n "$r" ] && claim_delete_ref "$slug" "$r"; done
}

# --- fallback: marker comments, when refs are forbidden -------------------
# Not a real lock — GitHub has no conditional comment create — so this is
# optimistic claim + deterministic arbitration. Comment ids are monotonic;
# created_at has only 1-second precision and cannot break ties.
claim_try_comment() {
  local slug="$1" pr="$2" head="$3" mine body
  body="$(render_marker claim "$(jq -nc --argjson pr "$pr" --arg head "$head" \
            --arg by "$GOBLIN_LOGIN" --argjson at "$(now_epoch)" \
            '{v:1,pr:$pr,headSha:$head,by:$by,at:$at}')")
🤖 $GOBLIN_NAME is reviewing this commit…"
  mine="$(gh api -X POST "repos/$slug/issues/$pr/comments" -f body="$body" --jq '.id' 2>/dev/null)"
  [ -z "$mine" ] && return 1

  sleep 20   # settle window: must exceed API read-after-write lag and clock skew

  local winner
  winner="$(gh api --paginate "repos/$slug/issues/$pr/comments?per_page=100" --jq \
    "[.[] | select(.body != null and (.body | contains(\"$GOBLIN_MARKER_NS:claim\")) and (.body | contains(\"$head\"))) | .id] | min" 2>/dev/null)"
  if [ "$winner" = "$mine" ]; then
    CLAIM_COMMENT_ID="$mine"; CLAIM_SLUG="$slug"
    return 0
  fi
  gh api -X DELETE "repos/$slug/issues/comments/$mine" --silent >/dev/null 2>&1 || true
  return 1
}

claim_release_comment() {
  [ -n "${CLAIM_COMMENT_ID:-}" ] || return 0
  gh api -X DELETE "repos/$CLAIM_SLUG/issues/comments/$CLAIM_COMMENT_ID" --silent >/dev/null 2>&1 || true
  CLAIM_COMMENT_ID=""
}
