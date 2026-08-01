#!/usr/bin/env bash
# engine.sh — poll → gate → claim → review → post → release.
#
# Gate order is cheapest-first on purpose: most cycles do no network work at all.
#   draft → local ledger → fleet assignment → GitHub idempotency → atomic claim

# shellcheck source=providers.sh
. "$LIB_DIR/providers.sh"
. "$LIB_DIR/findings.sh"
. "$LIB_DIR/github.sh"
. "$LIB_DIR/render.sh"
. "$LIB_DIR/post.sh"
. "$LIB_DIR/claim.sh"
. "$LIB_DIR/prompt.sh"
. "$LIB_DIR/diff.sh"
. "$LIB_DIR/update.sh"

ONLY_PR=""; ONLY_REPO=""; DRY_RUN=false; FORCE=false; SCHEDULED=false
REVIEWS_THIS_RUN=0

cmd_run() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)        ONLY_PR="$2"; shift 2 ;;
      --repo)      ONLY_REPO="$2"; shift 2 ;;
      --plan|--dry-run) DRY_RUN=true; shift ;;
      --force)     FORCE=true; shift ;;
      --scheduled) SCHEDULED=true; shift ;;
      *) echo "goblin run: unknown option $1" >&2; return 2 ;;
    esac
  done

  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs
  # Only the scheduled path writes to the log file; interactive runs print.
  [ "$SCHEDULED" = true ] && log_open

  if ! lock_acquire; then log "another run is active, exiting"; return 0; fi
  trap 'claim_release; claim_release_comment; lock_release' EXIT INT TERM

  log "=== run start ${ONLY_PR:+(pr #$ONLY_PR) }${DRY_RUN:+}$([ "$DRY_RUN" = true ] && echo '(dry run)')"

  engine_gates || { lock_release; return 0; }
  engine_auth  || { lock_release; return 1; }

  local provider
  # Load the adapters in THIS shell. providers_pick also loads them, but it runs
  # inside a command substitution — a subshell — so its sourcing is discarded and
  # provider_<name>_review would not exist by the time the engine calls it.
  providers_load
  provider="$(providers_pick)" || {
    log "no usable provider (run: goblin provider list)"
    status_set '{"state":"error","activity":"no usable AI provider"}'
    return 1
  }
  log "provider: $provider"

  local slug repos
  repos="$(cfg_repos_enabled)"
  [ -n "$ONLY_REPO" ] && repos="$ONLY_REPO"
  if [ -z "$repos" ]; then
    log "no repos configured — run: goblin repos add owner/name"
    return 0
  fi

  for slug in $repos; do
    engine_repo "$slug" "$provider"
  done

  # After the reviews, never before: a version check is the least important thing
  # this run does and must not delay or risk the work. Throttled to once a day
  # inside update_check, and it runs before the status write below so the panel
  # picks the flag up on this run rather than the next one.
  update_check
  local newer; newer="$(update_available)" && \
    log "update available: v$GOBLIN_VERSION → v$newer ($(update_instructions))"

  local fin; fin="$(now_epoch)"
  status_set "$(jq -nc --argjson f "$fin" \
    --argjson n "$((fin + $(cfg_get '.intervalSeconds' 900)))" \
    '{state:"idle",pausedReason:"",activity:"",lastRunFinished:$f,nextRunEstimate:$n}')"
  log "=== run done ($REVIEWS_THIS_RUN reviewed) ==="
}

# --- gates ----------------------------------------------------------------
engine_gates() {
  # A targeted run is a deliberate manual act; it bypasses the scheduling gates.
  [ -n "$ONLY_PR" ] && return 0
  [ "$FORCE" = true ] && return 0

  if [ "$(cfg_get '.enabled' true)" != "true" ]; then
    log "disabled via config"; status_set '{"state":"paused","pausedReason":"manual","activity":""}'; return 1
  fi
  local snooze now; snooze="$(cfg_get '.snoozeUntil' 0)"; now="$(now_epoch)"
  if [ "${snooze:-0}" -gt 0 ] 2>/dev/null; then
    if [ "$now" -lt "$snooze" ]; then
      log "snoozed until $snooze"
      status_set "$(jq -nc --argjson u "$snooze" '{state:"snoozed",pausedReason:"snoozed",snoozeUntil:$u}')"
      return 1
    fi
    log "snooze expired"; cfg_set '.snoozeUntil=0'
  fi
  engine_budget_ok || return 1

  status_set "$(jq -nc --argjson t "$now" '{state:"idle",pausedReason:"",activity:"",lastRunStarted:$t}')"
  return 0
}

# Checked before EVERY review, not just at run start — a backlog run used to
# blow past the cap by 2x before the next cycle noticed.
engine_budget_ok() {
  local cap spent max_run
  cap="$(cfg_get '.budgetCapUsd' 0)"
  max_run="$(cfg_get '.maxReviewsPerRun' 5)"

  if [ "${max_run:-0}" -gt 0 ] && [ "$REVIEWS_THIS_RUN" -ge "$max_run" ]; then
    log "hit maxReviewsPerRun ($max_run) — stopping this cycle"
    return 1
  fi
  spent="$(today_spend)"
  if [ "$(jq -n --argjson c "${cap:-0}" --argjson s "${spent:-0}" '($c>0) and ($s>=$c)' 2>/dev/null)" = "true" ]; then
    log "daily budget reached (\$$spent >= \$$cap)"
    local marker="$GOBLIN_HOME/.budget-notified" today; today="$(date +%Y-%m-%d)"
    if [ "$(cat "$marker" 2>/dev/null)" != "$today" ]; then
      notify budget "$GOBLIN_NAME paused 💸" "daily budget \$$cap reached (\$$spent) — resumes tomorrow"
      echo "$today" > "$marker"
    fi
    status_set '{"state":"paused","pausedReason":"budget","activity":""}'
    return 1
  fi
  return 0
}

engine_auth() {
  command -v gh  >/dev/null 2>&1 || { log "gh not found"; return 1; }
  command -v git >/dev/null 2>&1 || { log "git not found"; return 1; }
  GOBLIN_LOGIN="$(goblin_login)"
  gh_pin_token "$GOBLIN_LOGIN" || { log "could not obtain a gh token for '$GOBLIN_LOGIN'"; return 1; }
  if ! gh_assert_identity "$GOBLIN_LOGIN"; then
    log "token identity mismatch: token is '$(gh api user --jq .login 2>/dev/null)', expected '$GOBLIN_LOGIN' — abort"
    notify failed "$GOBLIN_NAME ⚠️" "github token is not $GOBLIN_LOGIN"
    return 1
  fi
  # launchd can't reach the macOS keychain, so git gets its credentials from the
  # token via URL rewrite. Env vars mean every child git process inherits it.
  export GIT_CONFIG_COUNT=1
  export GIT_CONFIG_KEY_0="url.https://x-access-token:${GH_TOKEN}@github.com/.insteadOf"
  export GIT_CONFIG_VALUE_0="https://github.com/"
  return 0
}

# --- per repo -------------------------------------------------------------
engine_repo() {
  local slug="$1" provider="$2" prs="$RUNTMP/prs-$$.json"

  if [ -n "$ONLY_PR" ]; then
    local meta="$RUNTMP/meta-$$.json"
    gh_pr_meta "$slug" "$ONLY_PR" "$meta" || { log "$slug#$ONLY_PR: not found"; return 1; }
    jq -c '[{number, head, draft:false, title, url, base, author,
             updatedAt:0, requested:[]}]' "$meta" > "$prs" 2>/dev/null
  else
    gh_prs "$slug" "$prs" || { log "$slug: could not list PRs (no access?)"; return 1; }
  fi

  # Oldest PR first. `gh pr list` returns newest-first, which is exactly the
  # wrong order under a per-run cap: the PR closest to being merged is the one
  # that gets reviewed last, or not at all. #1441 was the oldest of the three
  # queued at 12:34 and was served third, 6 minutes after it merged.
  if [ -z "$ONLY_PR" ]; then
    jq 'sort_by(.createdAt // 0)' "$prs" > "$prs.sorted" 2>/dev/null \
      && [ -s "$prs.sorted" ] && mv "$prs.sorted" "$prs"
  fi

  local n; n="$(jq 'length' "$prs" 2>/dev/null || echo 0)"
  log "$slug: $n open PR(s)"

  local i=0 entry
  while [ "$i" -lt "${n:-0}" ]; do
    entry="$(jq -c --argjson i "$i" '.[$i]' "$prs")"
    i=$((i + 1))
    engine_pr "$slug" "$entry" "$provider" || true
  done
  rm -f "$prs" "$prs.sorted" 2>/dev/null
}

# --- failure backoff -------------------------------------------------------
# Oldest-first ordering plus a 5-minute poll means a permanently-failing PR sits
# at the head of every queue and burns a model call each time. Honour the
# `failure` block that config.json has always carried: after maxAttempts, hold
# that COMMIT off until the backoff expires. A new push clears it, because the
# key includes the sha.
attempt_file() { printf '%s/attempts.json' "$GOBLIN_HOME"; }

attempt_blocked() {
  local key="$1" f; f="$(attempt_file)"
  [ -f "$f" ] || return 1
  local next; next="$(jq -r --arg k "$key" '.[$k].nextAt // 0' "$f" 2>/dev/null)"
  [ "${next:-0}" = "null" ] && next=0
  [ "$(now_epoch)" -lt "${next:-0}" ] 2>/dev/null
}

attempt_record() {
  local key="$1" kind="${2:-other}" f; f="$(attempt_file)"
  [ -f "$f" ] || echo '{}' > "$f"
  local maxa base cap n delay
  maxa="$(cfg_get '.failure.maxAttempts' 3)"
  base="$(cfg_get '.failure.backoffBaseSecs' 3600)"
  cap="$(cfg_get '.failure.maxBackoffSecs' 86400)"
  n="$(jq -r --arg k "$key" '.[$k].n // 0' "$f" 2>/dev/null)"; n=$((${n:-0} + 1))
  # Only start backing off once the PR has burned its free attempts; a single
  # transient blip should retry on the very next poll.
  if [ "$n" -lt "${maxa:-3}" ]; then delay=0; else
    delay="$base"; local k="$n"
    while [ "$k" -gt "${maxa:-3}" ] && [ "$delay" -lt "${cap:-86400}" ]; do
      delay=$((delay * 2)); k=$((k - 1))
    done
    [ "$delay" -gt "${cap:-86400}" ] && delay="$cap"
  fi
  jq --arg k "$key" --argjson n "$n" --argjson at "$(now_epoch)" \
     --argjson next "$(( $(now_epoch) + delay ))" --arg kind "$kind" \
     '.[$k] = {n:$n, lastAt:$at, nextAt:$next, kind:$kind}' "$f" > "$f.tmp" 2>/dev/null \
     && mv "$f.tmp" "$f"
  [ "$delay" -gt 0 ] && log "  #${key%%:*}: $n consecutive failures — holding this commit for $((delay / 60))m"
  return 0
}

attempt_clear() {
  local key="$1" f; f="$(attempt_file)"
  [ -f "$f" ] || return 0
  jq --arg k "$key" 'del(.[$k])' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
}

# --- per PR ---------------------------------------------------------------
engine_pr() {
  local slug="$1" entry="$2" provider="$3"
  local pr head title url base draft
  pr="$(printf '%s' "$entry"    | jq -r '.number')"
  head="$(printf '%s' "$entry"  | jq -r '.head')"
  title="$(printf '%s' "$entry" | jq -r '.title')"
  url="$(printf '%s' "$entry"   | jq -r '.url')"
  base="$(printf '%s' "$entry"  | jq -r '.base')"
  draft="$(printf '%s' "$entry" | jq -r '.draft')"

  [ "$draft" = "true" ] && { log "  #$pr: draft, skipping"; return 0; }

  local key="${pr}:${head}"
  if [ "$FORCE" != true ] && [ -z "$ONLY_PR" ] && ledger_has "$key"; then return 0; fi

  if [ "$FORCE" != true ] && attempt_blocked "$key"; then
    log "  #$pr: backing off after repeated failures, skipping"
    return 0
  fi

  # --- gate: is this PR mine to review? (free) ---
  if [ -z "$ONLY_PR" ] && [ "$(cfg_get '.fleetAssignment' true)" = "true" ]; then
    local eligible assignee
    eligible="$(claim_eligible "$entry")"
    if [ -z "$eligible" ]; then
      return 0   # nobody in the fleet was asked — not ours
    fi
    assignee="$(claim_assignee "$pr" "$head" "$eligible")"
    if [ "$assignee" != "$GOBLIN_LOGIN" ]; then
      # Unless the assignee looks offline: without this, reviews vanish whenever
      # someone's laptop is asleep.
      local updated grace now
      updated="$(printf '%s' "$entry" | jq -r '.updatedAt // 0')"
      grace="$(cfg_get '.takeoverGraceSecs' 2700)"; now="$(now_epoch)"
      if [ "$(( now - ${updated:-0} ))" -lt "${grace:-2700}" ]; then
        log "  #$pr: assigned to $assignee, skipping"
        return 0
      fi
      log "  #$pr: assigned to $assignee but stale — attempting takeover"
    fi
  fi

  # --- gate: has this exact commit already been reviewed? (1 call) ---
  local prior last_sha=""
  prior="$(gh_prior_review "$slug" "$pr")"
  if [ -n "$prior" ]; then
    last_sha="$(printf '%s' "$prior" | jq -r '.m.headSha // ""')"
    if [ "$last_sha" = "$head" ] && [ "$FORCE" != true ]; then
      log "  #$pr: already reviewed at $(trunc "$head" 7)"
      ledger_add "$key"
      return 0
    fi
  fi

  engine_budget_ok || return 1

  # --- gate: is it still open? (1 call, saves a whole model run) ---
  # The PR list is a snapshot from the top of the run; anything in it may have
  # merged since. Reviewing a merged PR costs a model call and posts advice
  # nobody will read.
  if [ "$DRY_RUN" != true ] && ! gh_pr_is_open "$slug" "$pr"; then
    log "  #$pr: already merged or closed, skipping"
    ledger_add "$key"
    return 0
  fi

  # --- gate: atomic claim (authoritative) ---
  if [ "$DRY_RUN" != true ] && [ -z "$ONLY_PR" ]; then
    if [ "$(cfg_get '.refsForbidden' false)" = "true" ]; then
      claim_try_comment "$slug" "$pr" "$head" || { log "  #$pr: another bot claimed it"; return 0; }
    else
      claim_try "$slug" "$pr" "$head"
      case $? in
        0) : ;;
        2) claim_try_comment "$slug" "$pr" "$head" || { log "  #$pr: claimed elsewhere"; return 0; } ;;
        *) log "  #$pr: claimed by another bot"; ledger_add "$key"; return 0 ;;
      esac
    fi
    claim_sweep "$slug" "$pr" "$head"
  fi

  engine_review_pr "$slug" "$pr" "$head" "$title" "$url" "$base" "$provider" "$last_sha"
  local rc=$?
  claim_release; claim_release_comment
  return $rc
}

# --- the actual review ----------------------------------------------------
engine_review_pr() {
  local slug="$1" pr="$2" head="$3" title="$4" url="$5" base="$6" provider="$7" last_sha="$8"
  local work="$RUNTMP/pr-$pr-$$"; rm -rf "$work"; mkdir -p "$work/raw"

  log "  #$pr: reviewing ($title)"
  status_set "$(jq -nc --arg a "reviewing #$pr — $title" '{state:"reviewing",activity:$a}')"
  notify started "$GOBLIN_NAME is reviewing" "#$pr — $title"
  [ "$DRY_RUN" != true ] && gh_status "$slug" "$head" pending "reviewing with $provider"

  # 1. the diff, from GitHub (source of truth for what is commentable)
  if ! diff_fetch_files "$slug" "$pr" "$work/files.json"; then
    log "  #$pr: no files returned"; rm -rf "$work"; return 1
  fi
  diff_addressable "$work/files.json" "$work/addr.json"
  diff_annotated  "$work/files.json" "$work/diff.txt" "$(cfg_get '.maxDiffBytes' 400000)"

  # 2. a checkout, so the model can read surrounding code
  local repo_dir; repo_dir="$(goblin_repo_dir "$slug")"
  engine_checkout "$slug" "$pr" "$repo_dir" || log "  #$pr: no local checkout (reviewing from diff only)"

  # 3. context: PR meta, ticket, findings already posted
  gh_pr_meta "$slug" "$pr" "$work/pr.json" || printf '{"number":%s,"title":"%s","body":"","base":"%s","author":""}' "$pr" "$title" "$base" > "$work/pr.json"
  gh_ticket_context "$slug" "$pr" "$work/pr.json" "$work/ticket.txt" >/dev/null
  : > "$work/prior.txt"
  local prior_json="$work/prior.json"; echo '[]' > "$prior_json"
  if [ -n "$last_sha" ] && [ "$(cfg_get '.incrementalReview' true)" = "true" ]; then
    gh_prior_findings "$slug" "$pr" > "$prior_json" 2>/dev/null || echo '[]' > "$prior_json"
    jq -r '.[] | "- \(.severity // "?"): \(.path // "?"):\(.line // "?")"' "$prior_json" > "$work/prior.txt" 2>/dev/null
    log "  #$pr: incremental (last reviewed $(trunc "$last_sha" 7), $(jq 'length' "$prior_json") prior finding(s))"
  fi

  # 4. assemble the prompt from THIS repo's own review rules
  prompt_build "${repo_dir:-$work}" "$slug" "$work/pr.json" "$work/diff.txt" \
               "$work/ticket.txt" "$work/prior.txt" "$work/prompt.txt"

  if [ "$DRY_RUN" = true ]; then
    engine_dry_run "$work" "$slug" "$pr" "$head" "$base" "$provider"
    rm -rf "$work"; return 0
  fi

  # 5. run the model
  if ! findings_run "$provider" "$work/prompt.txt" "${repo_dir:-$work}" "$work/norm.json" "$work/raw"; then
    local kind="${GOBLIN_P_ERRKIND:-other}"
    log "  #$pr: review failed ($kind) ${GOBLIN_P_ERRMSG:-}"
    # Keep the evidence. Without this a failure is unreproducible — you'd have
    # to pay for another review just to see what the model actually said.
    rm -rf "$GOBLIN_HOME/last-failure"
    cp -R "$work" "$GOBLIN_HOME/last-failure" 2>/dev/null \
      && log "  #$pr: raw output kept at $GOBLIN_HOME/last-failure"
    events_append failed "$pr" "$title" "$url" "${GOBLIN_P_COST_USD:-0}" "$kind" "$slug" "$provider" "${GOBLIN_P_MODEL:-}"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — $kind"
    gh_status "$slug" "$head" error "review failed: $kind"
    attempt_record "${pr}:${head}" "$kind"
    status_set '{"state":"idle","activity":""}'
    rm -rf "$work"; return 1
  fi

  # 6. drop findings that were already posted and still stand
  if [ -s "$prior_json" ] && [ "$(jq 'length' "$prior_json")" != "0" ]; then
    jq --slurpfile prior "$prior_json" \
      '.findings |= map(select(. as $f | ($prior[0] | map(.id) | index($f.id)) == null))' \
      "$work/norm.json" > "$work/norm2.json" 2>/dev/null && mv "$work/norm2.json" "$work/norm.json"
  fi

  engine_publish "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$prior_json"
  local rc=$?
  rm -rf "$work"
  return $rc
}

engine_publish() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" title="$6" url="$7" provider="$8" prior_json="$9"
  local model="${GOBLIN_P_MODEL:-$provider}" cost="${GOBLIN_P_COST_USD:-0}"

  diff_split_findings "$work/norm.json" "$work/addr.json" "$work/split.json"
  local event; event="$(findings_verdict "$work/norm.json")"
  render_review_body "$work/norm.json" "$work/split.json" "$pr" "$head" "$base" \
                     "$provider" "$model" "$GOBLIN_LOGIN" "$work/files.json" "$event" > "$work/body.md"
  if ! post_build_review "$work/split.json" "$work/body.md" "$head" "$event" \
                         "$provider" "$model" "$pr" "$work/review.json"; then
    events_append failed "$pr" "$title" "$url" "$cost" "payload incomplete" "$slug" "$provider" "$model"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — review payload was incomplete"
    gh_status "$slug" "$head" error "review payload was incomplete"
    attempt_record "${pr}:${head}" "payload"
    return 1
  fi

  # Second liveness check. The model run above takes a minute or two, which is
  # long enough on this repo for the PR to merge underneath us.
  if ! gh_pr_is_open "$slug" "$pr"; then
    log "  #$pr: merged or closed during the review — not posting"
    ledger_add "${pr}:${head}"
    status_set '{"state":"idle","activity":""}'
    return 0
  fi

  local review_url
  if ! review_url="$(post_review "$slug" "$pr" "$work/review.json" "$work/err.json")"; then
    log "  #$pr: posting failed — $(head -c 200 "$work/err.json" 2>/dev/null)"
    events_append failed "$pr" "$title" "$url" "$cost" "post failed" "$slug" "$provider" "$model"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — could not post review"
    gh_status "$slug" "$head" error "could not post review"
    attempt_record "${pr}:${head}" "post"
    return 1
  fi

  # the second comment: does this do what the ticket asked?
  local intent; intent="$(jq -c '.intent_note // empty' "$work/norm.json" 2>/dev/null)"
  if [ -n "$intent" ] && [ "$(printf '%s' "$intent" | jq -r '.verdict')" != "no_ticket" ]; then
    render_intent_body "$intent" "$pr" "$head" "$provider" "$model" "$GOBLIN_LOGIN" > "$work/intent.md"
    post_intent "$slug" "$pr" "$work/intent.md"
  fi

  # tell prior threads that their finding is gone
  if [ -s "$prior_json" ] && [ "$(jq 'length' "$prior_json")" != "0" ]; then
    jq -c '[.findings[].id]' "$work/norm.json" > "$work/curids.json"
    post_fixed_replies "$slug" "$pr" "$prior_json" "$work/curids.json" "$head"
  fi

  local counts inline_n
  counts="$(render_counts "$work/norm.json")"
  inline_n="$(jq '.inline | length' "$work/split.json")"
  gh_status "$slug" "$head" success "$counts · $model" "$review_url"

  ledger_add "${pr}:${head}"
  attempt_clear "${pr}:${head}"
  events_append posted "$pr" "$title" "$url" "$cost" "" "$slug" "$provider" "$model"
  REVIEWS_THIS_RUN=$((REVIEWS_THIS_RUN + 1))
  log "  #$pr: posted — $counts ($inline_n inline)${cost:+, \$$cost}"
  notify posted "$GOBLIN_NAME posted ✅" "#$pr — $counts"
  status_set '{"state":"idle","activity":""}'
  return 0
}

engine_dry_run() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" provider="$6"
  echo
  echo "── dry run: $slug#$pr @ $(trunc "$head" 7) ────────────────────"
  echo "provider:          $provider"
  echo "prompt:            $(wc -c < "$work/prompt.txt" | tr -d ' ') bytes  ($work/prompt.txt)"
  echo "diff:              $(wc -c < "$work/diff.txt" | tr -d ' ') bytes, $(jq 'length' "$work/files.json") files"
  echo "addressable lines: $(jq 'length' "$work/addr.json")"
  echo "review rules from: $(prompt_discover "$(goblin_repo_dir "$slug")" "$slug" 2>/dev/null | sed "s|$(goblin_repo_dir "$slug")/||" || echo '(built-in fallback)')"
  echo "ticket context:    $([ -s "$work/ticket.txt" ] && echo "$(wc -c < "$work/ticket.txt" | tr -d ' ') bytes" || echo none)"
  echo "verdict would be:  $(cfg_get '.verdictMode' comment) → (computed after findings)"
  echo
  echo "no model was called and nothing was posted."
  echo "to see the assembled prompt:  less $work/prompt.txt"
  # Keep the workdir for inspection. Remove any previous copy first: `cp -R src
  # dst` nests src INSIDE dst when dst already exists, which silently leaves the
  # stale run in place.
  rm -rf "$GOBLIN_HOME/last-dry-run"
  cp -R "$work" "$GOBLIN_HOME/last-dry-run" 2>/dev/null && echo "copy kept at: $GOBLIN_HOME/last-dry-run"
}

# Standalone clone (never a worktree under ~/Documents — macOS TCC blocks
# launchd from reading there), reset hard before every checkout because leftover
# dirty files made `gh pr checkout` abort on every PR once.
engine_checkout() {
  local slug="$1" pr="$2" dir="$3"
  if ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    log "  cloning $slug (one-time)"
    rm -rf "$dir"
    git clone --quiet "https://github.com/$slug.git" "$dir" >/dev/null 2>&1 || return 1
  fi
  git -C "$dir" fetch --quiet origin >/dev/null 2>&1 || return 1
  git -C "$dir" reset --hard --quiet >/dev/null 2>&1
  git -C "$dir" clean -ffd >/dev/null 2>&1
  ( cd "$dir" && gh pr checkout "$pr" --repo "$slug" --detach >/dev/null 2>&1 ) || return 1
  return 0
}
