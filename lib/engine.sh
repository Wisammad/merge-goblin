#!/usr/bin/env bash
# engine.sh — poll → gate → claim → review → post → release.
#
# Gate order is cheapest-first on purpose: most cycles do no network work at all.
#   draft → local ledger → fleet assignment → GitHub idempotency → atomic claim

# shellcheck source=providers.sh
. "$LIB_DIR/providers.sh"
. "$LIB_DIR/findings.sh"
. "$LIB_DIR/reviewers.sh"
. "$LIB_DIR/github.sh"
. "$LIB_DIR/render.sh"
. "$LIB_DIR/post.sh"
. "$LIB_DIR/claim.sh"
. "$LIB_DIR/prompt.sh"
. "$LIB_DIR/diff.sh"
. "$LIB_DIR/update.sh"
. "$LIB_DIR/attempts.sh"
. "$LIB_DIR/inbox.sh"

ONLY_PR=""; ONLY_REPO=""; AUTHOR_SCOPE=""; DRY_RUN=false; FORCE=false; SCHEDULED=false
UNTIL_CLEAN=false; MAX_PASSES=""
REVIEWS_THIS_RUN=0
RUN_LOCK_HELD=false
ACTIVE_CHECKOUT=""

cmd_run() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --pr)        ONLY_PR="$2"; shift 2 ;;
      --repo)      ONLY_REPO="$2"; shift 2 ;;
      --author)    AUTHOR_SCOPE="$2"; shift 2 ;;
      --plan|--dry-run) DRY_RUN=true; shift ;;
      --force)     FORCE=true; shift ;;
      --scheduled) SCHEDULED=true; shift ;;
      --until-clean) UNTIL_CLEAN=true; shift ;;
      --once)      UNTIL_CLEAN=false; shift ;;
      --max-passes)
        case "$2" in
          ''|*[!0-9]*|0) echo "goblin run: --max-passes wants a positive number, got '$2'" >&2; return 2 ;;
        esac
        MAX_PASSES="$2"; shift 2 ;;
      *) echo "goblin run: unknown option $1" >&2; return 2 ;;
    esac
  done

  # A dry run posts nothing, so pass 2 would read the same PR pass 1 read and
  # find the same things forever. Say so rather than quietly doing real reviews
  # (a sweep pass never carries --plan) or quietly looping on nothing.
  if [ "$UNTIL_CLEAN" = true ] && [ "$DRY_RUN" = true ]; then
    echo "$GOBLIN_SLUG run: --plan posts nothing, so there is nothing for a second pass to" >&2
    echo "  converge on — running a single dry pass." >&2
    UNTIL_CLEAN=false
  fi

  # A sweep is a loop OVER runs, not a mode of one, so it is decided before any
  # of the single-run setup below and delegates each pass to a fresh process.
  if [ "$UNTIL_CLEAN" = true ]; then
    cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs
    engine_sweep "$ONLY_REPO" "$ONLY_PR" "$MAX_PASSES"
    return $?
  fi

  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs
  # Only the scheduled path writes to the log file; interactive runs print.
  [ "$SCHEDULED" = true ] && log_open

  # Exact-PR audits use their own PR lock inside engine_pr. Everything that can
  # fan out across a repository keeps the global lock.
  if [ -z "$ONLY_PR" ]; then
    if ! lock_acquire; then log "another run is active, exiting"; return 0; fi
    RUN_LOCK_HELD=true
  fi
  # reservation_release here is a crash-safety net, not the primary release —
  # the per-PR loops in engine_repo/engine_user_scope release explicitly after
  # every PR so a sweep never holds one PR's slot into the next.
  trap 'claim_release; claim_release_comment; engine_checkout_release; pr_lock_release; reservation_release; engine_run_lock_release' EXIT INT TERM

  log "=== run start ${ONLY_PR:+(pr #$ONLY_PR) }${DRY_RUN:+}$([ "$DRY_RUN" = true ] && echo '(dry run)')"

  engine_gates || { engine_run_lock_release; return 0; }
  engine_auth  || { engine_run_lock_release; return 1; }

  local provider="orchestrated"
  # Load every adapter in THIS shell: contributor-aware reviews select two per PR.
  providers_load
  log "review mode: contributor-aware parallel reviewers"

  local slug repos
  if [ -n "$AUTHOR_SCOPE" ] && [ -z "$ONLY_REPO" ]; then
    engine_user_scope "$AUTHOR_SCOPE" "$provider"
    repos=""
  else
    repos="$(cfg_repos_enabled)"
    [ -n "$ONLY_REPO" ] && repos="$ONLY_REPO"
    if [ -z "$repos" ]; then
      log "no repos configured — run: goblin repos add owner/name"
      return 0
    fi

    for slug in $repos; do
      engine_repo "$slug" "$provider"
    done
  fi

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

engine_run_lock_release() {
  if [ "$RUN_LOCK_HELD" = true ]; then lock_release; RUN_LOCK_HELD=false; fi
}

engine_checkout_dir() {
  if [ -n "$ONLY_PR" ]; then printf '%s/checkout-%s-%s' "$RUNTMP" "$2" "$$"
  else goblin_repo_dir "$1"
  fi
}

engine_checkout_release() {
  [ -n "$ACTIVE_CHECKOUT" ] && rm -rf "$ACTIVE_CHECKOUT"
  ACTIVE_CHECKOUT=""
}

# --auto is intentionally a local head watcher, not a webhook server. It keeps
# one simple GitHub API loop alive and delegates each cycle to a fresh process so
# the existing run lock and cleanup traps retain their one-run lifetime.
cmd_auto() {
  local repo="${1:-}" login interval="${GOBLIN_WATCH_INTERVAL:-30}" rc=0
  if [ -n "$repo" ] && ! printf '%s' "$repo" | grep -Eq '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'; then
    echo "usage: $GOBLIN_SLUG --auto [OWNER/REPO]" >&2; return 2
  fi
  case "$interval" in ''|*[!0-9]*) interval=30 ;; esac
  [ "$interval" -lt 5 ] 2>/dev/null && interval=5

  cfg_ensure; cfg_backfill_defaults
  login="$(goblin_login)"
  [ -n "$login" ] || { echo "$GOBLIN_SLUG: configure a GitHub login first" >&2; return 1; }

  if [ -n "$repo" ]; then
    echo "$GOBLIN_EMOJI watching @$login's PR heads in $repo (Ctrl-C to stop)"
  else
    echo "$GOBLIN_EMOJI watching @$login's PR heads across GitHub (Ctrl-C to stop)"
  fi

  trap 'exit 0' INT TERM
  while :; do
    rc=0
    if [ -n "$repo" ]; then
      "$GOBLIN_APP/bin/$GOBLIN_SLUG" run --author "$login" --repo "$repo" || rc=$?
    else
      "$GOBLIN_APP/bin/$GOBLIN_SLUG" run --author "$login" || rc=$?
    fi
    [ "${GOBLIN_AUTO_ONCE:-false}" = "true" ] && break
    sleep "$interval"
  done
  return "$rc"
}

# --- sweep: one PR, reviewed until a pass finds nothing new ----------------
#
# One paste of a PR link used to be one review, and a second problem hiding
# behind the first stayed hidden until somebody ran the command again by hand.
# That manual restart worked for a reason worth automating: every pass reads the
# findings already posted on this PR (gh_prior_findings), tells the model not to
# raise them again, and posts only what is new. The passes therefore converge —
# the pass that adds nothing is the pass that says the PR is clean.
#
# "New" is decided from the finding IDS this sweep has already seen, not from a
# per-pass count. GitHub's own dedupe cannot close the loop on its own: it works
# off the inline comments on the PR (gh_prior_findings), and a finding on a line
# outside the diff is never an inline comment — it is demoted into the review
# body, where the next pass cannot see it, and would be raised again by every
# pass forever. Tracking ids here is what makes the sweep converge on those too.
#
# Bounded on purpose. Each pass is a real review: it spends a maxReviewsPerDay
# slot and real money on a provider that meters. maxPassesPerPr is the ceiling,
# and the loop stops well short of it on any outcome that is not "posted
# something new" — a failure, the daily cap, the PR merging underneath it. It
# never spins on a no-op.
engine_sweep() {
  local repo="$1" pr="$2" max="${3:-}"
  local result seen ids pass=0 outcome="" findings=0 fresh=0 total=0

  [ -n "$pr" ] || { echo "$GOBLIN_SLUG run --until-clean: needs --pr N" >&2; return 2; }
  if [ -z "$repo" ]; then
    # One configured repo is not ambiguous. Several are, and guessing which PR
    # #7 someone means is exactly the kind of guess that reviews the wrong PR.
    repo="$(cfg_repos_enabled | head -2 | paste -sd' ' -)"
    case "$repo" in
      "")    echo "$GOBLIN_SLUG run --until-clean: needs --repo OWNER/NAME" >&2; return 2 ;;
      *" "*) echo "$GOBLIN_SLUG run --until-clean: needs --repo OWNER/NAME (several repos are configured)" >&2; return 2 ;;
    esac
  fi

  # A pass must never start a sweep of its own. engine_sweep_pass exports
  # GOBLIN_SWEEP for exactly this, so a stray --until-clean reaching a child
  # costs one review instead of forking reviews without end.
  #
  # UNTIL_CLEAN has to be cleared before handing back to cmd_run, not just here:
  # it is a global that survives the call, so cmd_run would parse these three
  # arguments, still see it set, and come straight back into this function.
  if [ -n "${GOBLIN_SWEEP:-}" ]; then
    log "already inside a sweep — reviewing once"
    UNTIL_CLEAN=false
    cmd_run --repo "$repo" --pr "$pr" --force
    return $?
  fi

  [ -n "$max" ] || max="$(cfg_get '.maxPassesPerPr' 5)"
  case "$max" in ''|*[!0-9]*) max=5 ;; esac
  [ "$max" -lt 1 ] && max=1

  result="$RUNTMP/sweep-$$.json"
  seen="$RUNTMP/sweep-seen-$$.json"; echo '[]' > "$seen"
  log "sweeping $repo#$pr until a pass finds nothing new (at most $max pass(es))"

  while [ "$pass" -lt "$max" ]; do
    pass=$((pass + 1))
    rm -f "$result" 2>/dev/null
    log "--- pass $pass/$max ---"
    engine_sweep_pass "$repo" "$pr" "$result" || true

    # An absent or unreadable result means the pass never reached a decision it
    # could report: it was gated, it crashed, or someone interrupted it. There
    # is nothing to converge on either way, so stop rather than pay for another.
    outcome="$(jq -r '.outcome // ""' "$result" 2>/dev/null)"
    findings="$(jq -r '.findings // 0' "$result" 2>/dev/null)"
    case "$findings" in ''|*[!0-9]*) findings=0 ;; esac

    if [ "$outcome" != "posted" ]; then
      log "sweep stopped after pass $pass: ${outcome:-the pass reported no outcome}"
      break
    fi

    ids="$(jq -c '(.ids // []) | map(select(. != null))' "$result" 2>/dev/null)"
    printf '%s' "$ids" | jq -e 'type == "array"' >/dev/null 2>&1 || ids='[]'
    fresh="$(jq -n --argjson ids "$ids" --slurpfile seen "$seen" \
      '($ids - $seen[0]) | unique | length' 2>/dev/null)"
    case "$fresh" in ''|*[!0-9]*) fresh=0 ;; esac
    jq -n --argjson ids "$ids" --slurpfile seen "$seen" '($seen[0] + $ids) | unique' \
      > "$seen.t" 2>/dev/null && mv "$seen.t" "$seen"

    if [ "$fresh" -eq 0 ]; then
      if [ "$findings" -eq 0 ]; then
        log "pass $pass found nothing — $repo#$pr is clean after $pass pass(es), $total finding(s) posted"
      else
        log "pass $pass raised nothing this sweep had not already seen — done after $pass pass(es), $total finding(s) posted"
      fi
      rm -f "$result" "$seen" 2>/dev/null
      return 0
    fi
    total=$((total + fresh))
    log "pass $pass posted $fresh new finding(s) — going again"
  done

  rm -f "$result" "$seen" 2>/dev/null
  if [ "$outcome" != "posted" ]; then return 1; fi
  log "sweep hit its $max-pass cap and pass $max was still finding things ($total posted)"
  log "run it again, or raise maxPassesPerPr: $GOBLIN_SLUG config set .maxPassesPerPr $((max + 3))"
  return 1
}

# engine_sweep_pass <repo> <pr> <result-file>
#
# One pass, in a FRESH process — the same delegation cmd_auto uses for its
# cycles, for the same reasons. Looping in-process would carry pass 1's
# REVIEWS_THIS_RUN, EXIT trap, claim and quota reservation into pass 2:
# maxReviewsPerRun (5) alone would have silently capped every sweep, and the
# cleanup trap would fire once at the very end instead of after each pass.
engine_sweep_pass() {
  GOBLIN_SWEEP=1 GOBLIN_PASS_RESULT="$3" \
    "$GOBLIN_APP/bin/$GOBLIN_SLUG" run --repo "$1" --pr "$2" --force
}

# engine_pass_write <outcome> [findings] [head] [ids-json] — how this run ended,
# for the sweep loop that spawned it. A no-op when nobody asked, so no other
# caller has to know the mechanism exists.
#
# Written only where a run reaches a decision. Every other exit leaves the file
# absent, and engine_sweep reads absence as "stop" — the loop continues on an
# explicit `posted` carrying a finding id it has not seen, and on nothing else,
# so a path nobody instrumented can cost a sweep its remaining passes but can
# never make it spin.
engine_pass_write() {
  [ -n "${GOBLIN_PASS_RESULT:-}" ] || return 0
  local ids="${4:-[]}"
  printf '%s' "$ids" | jq -e 'type == "array"' >/dev/null 2>&1 || ids='[]'
  jq -nc --arg o "$1" --argjson f "${2:-0}" --arg h "${3:-}" --argjson ids "$ids" \
    '{outcome:$o, findings:$f, head:$h, ids:$ids}' > "$GOBLIN_PASS_RESULT" 2>/dev/null || true
}

# `goblin <PR_URL>` — review exactly the pull request someone pasted.
#
# This was one branch of a `--manual` command that also took OWNER/REPO and
# OWNER/REPO#N, and prompted for a target when given neither. All of it ended in
# the same `goblin run --repo … --pr … --force` that `goblin run` already spells
# out, so --manual added a second syntax and an interactive prompt on top of a
# link people can paste straight from the browser. Repo-wide and exact-PR runs
# without a link are `goblin run --repo OWNER/NAME [--pr N] --force`.
cmd_url() {
  local url="${1:-}" parsed repo pr arg once=false
  shift 2>/dev/null || true
  # GitHub's Files/Commits/Checks tabs put a path segment after the number
  # (.../pull/23/files, .../pull/23/checks?check_run_id=5) — exactly what the
  # address bar holds on those tabs, and a normal thing to paste. `/?` only
  # tolerated a single bare trailing slash, so those pastes were rejected.
  parsed="$(printf '%s' "$url" | sed -nE \
    's|^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)/pull/([1-9][0-9]*)(/[^?#]*)?([?#].*)?$|\1/\2 \3|p')"
  [ -n "$parsed" ] || { echo "not a GitHub pull request URL: $url" >&2; return 2; }
  repo="${parsed% *}"; pr="${parsed##* }"

  for arg in "$@"; do
    case "$arg" in
      --once) once=true ;;
      # A dry run posts nothing, so there is no new posted finding for a second
      # pass to read back and nothing for the loop to converge on. One pass.
      --plan|--dry-run) once=true ;;
    esac
  done

  # A pasted link is someone asking about one specific PR, which is the one case
  # where reviewing it exhaustively is worth several passes — see engine_sweep.
  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs
  if [ "$once" != true ] && [ "$(cfg_get '.sweepUntilClean' true)" = "true" ]; then
    engine_sweep "$repo" "$pr" ""
    return $?
  fi
  # --force because pasting a link is a deliberate act: it bypasses the snooze
  # and the configured repo scope exactly as the old --manual did.
  cmd_run --repo "$repo" --pr "$pr" --force "$@"
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
  local cap spent max_run max_day done_today
  cap="$(cfg_get '.budgetCapUsd' 0)"
  max_run="$(cfg_get '.maxReviewsPerRun' 5)"
  max_day="$(cfg_get '.maxReviewsPerDay' 0)"

  if [ "${max_run:-0}" -gt 0 ] && [ "$REVIEWS_THIS_RUN" -ge "$max_run" ]; then
    log "hit maxReviewsPerRun ($max_run) — stopping this cycle"
    return 1
  fi

  # A count cap as well as a dollar cap, because the dollar cap cannot protect a
  # subscription provider: `cost not reported` means today_spend() stays at 0
  # forever and budgetCapUsd never fires. On a repo with a large backlog that is
  # an unbounded number of reviews against a subscription with its own hidden
  # quota — and hitting a provider's quota is the failure that takes the Goblin
  # down for everyone on the team, not just for the PR that tripped it.
  if [ "${max_day:-0}" -gt 0 ] 2>/dev/null; then
    # Add in-flight reservations, not just posted events, so this cheap
    # pre-filter is not wildly stale — but it is still just a pre-filter, not
    # the authoritative gate: reservation_try below is the atomic one.
    done_today="$(( $(today_review_count) + $(reservation_count) ))"
    if [ "${done_today:-0}" -ge "$max_day" ] 2>/dev/null; then
      log "hit maxReviewsPerDay ($done_today/$max_day) — resumes tomorrow"
      status_set '{"state":"paused","pausedReason":"quota","activity":""}'
      engine_pass_write "the daily review cap ($done_today/$max_day) is reached"
      return 1
    fi
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
    engine_pass_write "the \$$cap daily budget is spent (\$$spent)"
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
    if [ -n "$AUTHOR_SCOPE" ]; then
      jq --arg a "$(lc "$AUTHOR_SCOPE")" \
        'map(select(((.author // "") | ascii_downcase) == $a))' "$prs" > "$prs.author" 2>/dev/null \
        && mv "$prs.author" "$prs"
    fi
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
    # Release whatever this PR reserved (see reservation_try), win or lose —
    # a sweep must not still be holding PR #1's slot while it starts on #2.
    reservation_release
  done
  rm -f "$prs" "$prs.sorted" 2>/dev/null
}

engine_user_scope() {
  local author="$1" provider="$2" prs="$RUNTMP/user-prs-$$.json"
  gh_user_prs "$author" "$prs" || { log "could not find open PRs for @$author"; return 1; }
  jq 'sort_by(.createdAt // 0)' "$prs" > "$prs.sorted" 2>/dev/null \
    && mv "$prs.sorted" "$prs"

  local n i=0 entry slug
  n="$(jq 'length' "$prs" 2>/dev/null || echo 0)"
  log "@$author: $n open PR(s) across GitHub"
  while [ "$i" -lt "${n:-0}" ]; do
    entry="$(jq -c --argjson i "$i" '.[$i]' "$prs")"; i=$((i + 1))
    slug="$(printf '%s' "$entry" | jq -r '.repo')"
    engine_pr "$slug" "$entry" "$provider" || true
    reservation_release
  done
  rm -f "$prs" 2>/dev/null
}

# --- failure backoff -------------------------------------------------------
# Moved to lib/attempts.sh (sourced above) so inbox.sh and state.sh can read the
# same file without sourcing this one. Behaviour is unchanged.

# --- per PR ---------------------------------------------------------------
engine_pr() {
  local slug="$1" entry="$2" provider="$3" pr rc
  pr="$(printf '%s' "$entry" | jq -r '.number')"
  if ! pr_lock_acquire "$slug" "$pr"; then
    log "  #$pr: another review of this PR is active, skipping"
    return 0
  fi
  engine_pr_unlocked "$slug" "$entry" "$provider"; rc=$?
  pr_lock_release
  return "$rc"
}

engine_pr_unlocked() {
  local slug="$1" entry="$2" provider="$3"
  local pr head title url base draft
  pr="$(printf '%s' "$entry"    | jq -r '.number')"
  head="$(printf '%s' "$entry"  | jq -r '.head')"
  title="$(printf '%s' "$entry" | jq -r '.title')"
  url="$(printf '%s' "$entry"   | jq -r '.url')"
  base="$(printf '%s' "$entry"  | jq -r '.base')"
  draft="$(printf '%s' "$entry" | jq -r '.draft')"

  [ "$draft" = "true" ] && { log "  #$pr: draft, skipping"; return 0; }

  local key="${slug}#${pr}:${head}"
  if [ "$FORCE" != true ] && [ -z "$ONLY_PR" ] && ledger_reviewed "$slug" "$pr" "$head"; then return 0; fi

  if [ "$FORCE" != true ] && attempt_blocked "$key"; then
    log "  #$pr: backing off after repeated failures, skipping"
    return 0
  fi

  # --- gate: is this PR mine to review? (free) ---
  if [ "$FORCE" != true ] && [ -z "$ONLY_PR" ] && [ -z "$AUTHOR_SCOPE" ] \
     && [ "$(cfg_get '.fleetAssignment' true)" = "true" ]; then
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

  # --- gate: has a person already reviewed it? ---
  # Free: reuses the reviews page fetched for the gate above. The Goblin exists to
  # look at PRs nobody has looked at; once a colleague has left a real review,
  # adding an automated one on top is noise on a thread that already has a human
  # owner. Its own reviews are excluded by marker inside gh_human_reviewers — they
  # are posted under a human token and are otherwise indistinguishable, and without
  # that exclusion the Goblin sees itself and never reviews the repo again.
  if [ "$(cfg_get '.skipIfHumanReviewed' true)" = "true" ] && [ "$FORCE" != true ] \
     && [ -z "$ONLY_PR" ] && [ -z "$AUTHOR_SCOPE" ]; then
    local rj humans; rj="$RUNTMP/reviews-$pr-$$.json"
    if gh_reviews_fetch "$slug" "$pr" "$rj"; then
      humans="$(gh_human_reviewers "$rj" | paste -sd, - 2>/dev/null)"
      if [ -n "$humans" ]; then
        log "  #$pr: already reviewed by $humans, skipping"
        ledger_add "$key"
        rm -f "$rj" 2>/dev/null
        return 0
      fi
    fi
    rm -f "$rj" 2>/dev/null
  fi

  # engine_budget_ok is a cheap, non-atomic pre-filter — it can and does race
  # under concurrent exact-PR audits, so it is not the authoritative gate.
  # reservation_try is: it recounts posted+reserved and reserves this slot in
  # ONE locked step, so only as many concurrent audits as maxReviewsPerDay
  # allows ever get past it, whatever engine_budget_ok itself saw.
  engine_budget_ok || return 1
  # A dry run (`goblin run --plan`) never posts anything, so it must never
  # occupy a real quota slot — reserving one here blocked a genuine
  # concurrent audit with a quota error over a run that was only previewing.
  if [ "$DRY_RUN" != true ]; then
    local max_day; max_day="$(cfg_get '.maxReviewsPerDay' 0)"
    if ! reservation_try "${slug}#${pr}:$$" "$max_day"; then
      log "  #$pr: hit maxReviewsPerDay ($max_day) — resumes tomorrow"
      status_set '{"state":"paused","pausedReason":"quota","activity":""}'
      engine_pass_write "the daily review cap ($max_day) is reached"
      return 1
    fi
  fi

  # --- gate: is it still open? (1 call, saves a whole model run) ---
  # The PR list is a snapshot from the top of the run; anything in it may have
  # merged since. Reviewing a merged PR costs a model call and posts advice
  # nobody will read.
  if [ "$DRY_RUN" != true ] && ! gh_pr_is_open "$slug" "$pr"; then
    log "  #$pr: already merged or closed, skipping"
    ledger_add "$key"
    engine_pass_write "the PR is merged or closed"
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
  [ "$DRY_RUN" != true ] && gh_status "$slug" "$head" pending "selecting independent reviewers"

  # 1. the diff, from GitHub (source of truth for what is commentable)
  if ! diff_fetch_files "$slug" "$pr" "$work/files.json"; then
    log "  #$pr: no files returned"
    engine_pass_write "GitHub returned no changed files"
    rm -rf "$work"; return 1
  fi
  diff_addressable "$work/files.json" "$work/addr.json"
  diff_annotated  "$work/files.json" "$work/diff.txt" "$(cfg_get '.maxDiffBytes' 400000)"

  # 2. a checkout, so the model can read surrounding code
  local repo_dir isolated_checkout=false
  repo_dir="$(engine_checkout_dir "$slug" "$pr")"
  if [ -n "$ONLY_PR" ]; then isolated_checkout=true; ACTIVE_CHECKOUT="$repo_dir"; fi
  if ! engine_checkout "$slug" "$pr" "$repo_dir"; then
    log "  #$pr: no local checkout (reviewing from diff only)"
    [ "$isolated_checkout" = true ] && engine_checkout_release
    repo_dir="$work"; isolated_checkout=false
  fi

  # 3. context: PR meta, ticket, findings already posted
  gh_pr_meta "$slug" "$pr" "$work/pr.json" || printf '{"number":%s,"title":"%s","body":"","base":"%s","author":""}' "$pr" "$title" "$base" > "$work/pr.json"
  gh_pr_agent_evidence "$slug" "$pr" "$work/pr.json" "$work/agent-evidence.txt"
  reviewers_plan "$work/agent-evidence.txt" "$work/review-plan.json"
  local contributor reviewer_names plan_note
  # Every detected contributor, not just the highest-scoring one — the whole
  # point is that none of them is asked to review.
  contributor="$(jq -r 'if (.contributors // []) | length > 0
                        then [.contributors[].label] | join(" + ")
                        else "none detected" end' "$work/review-plan.json")"
  reviewer_names="$(jq -r '[.reviewers[].label] | join(" + ")' "$work/review-plan.json")"
  plan_note="$(jq -r '.note // ""' "$work/review-plan.json")"
  log "  #$pr: coding-agent contributor(s): $contributor"
  log "  #$pr: independent reviewers (parallel): $reviewer_names"
  [ -n "$plan_note" ] && log "  #$pr: $plan_note"
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
    [ "$isolated_checkout" = true ] && engine_checkout_release
    rm -rf "$work"; return 0
  fi

  # 5. run both non-contributor reviewers concurrently, then merge their output.
  if ! reviewers_run "$work/review-plan.json" "$work/prompt.txt" "${repo_dir:-$work}" "$work" \
     || ! reviewers_merge "$work/review-plan.json" "$work" "$work/norm.json" "$work/review-plan-final.json"; then
    local kind="reviewer_failure" errors
    errors="$(jq -rs '[.[] | select(.ok != true) | (.provider + ": " + (.error // "failed"))] | join("; ")' "$work"/meta-*.json 2>/dev/null)"
    log "  #$pr: independent review failed ${errors:+($errors)}"
    # Keep the evidence. Without this a failure is unreproducible — you'd have
    # to pay for another review just to see what the model actually said.
    rm -rf "$GOBLIN_HOME/last-failure"
    cp -R "$work" "$GOBLIN_HOME/last-failure" 2>/dev/null \
      && log "  #$pr: raw output kept at $GOBLIN_HOME/last-failure"
    events_append failed "$pr" "$title" "$url" 0 "$kind" "$slug" "$provider" "$reviewer_names"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — $kind"
    gh_status "$slug" "$head" error "review failed: $kind"
    attempt_record "${slug}#${pr}:${head}" "$kind"
    status_set '{"state":"idle","activity":""}'
    engine_pass_write "the review itself failed${errors:+ ($errors)}" 0 "$head"
    [ "$isolated_checkout" = true ] && engine_checkout_release
    rm -rf "$work"; return 1
  fi

  # 6. drop findings that were already posted and still stand
  if [ -s "$prior_json" ] && [ "$(jq 'length' "$prior_json")" != "0" ]; then
    jq --slurpfile prior "$prior_json" \
      '.findings |= map(select(. as $f | ($prior[0] | map(.id) | index($f.id)) == null))' \
      "$work/norm.json" > "$work/norm2.json" 2>/dev/null && mv "$work/norm2.json" "$work/norm.json"
  fi

  engine_publish "$work" "$slug" "$pr" "$head" "$base" "$title" "$url" "$provider" "$prior_json" "$last_sha"
  local rc=$?
  [ "$isolated_checkout" = true ] && engine_checkout_release
  rm -rf "$work"
  return $rc
}

engine_publish() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" title="$6" url="$7" provider="$8" prior_json="$9"
  local last_sha="${10:-}"
  local plan="$work/review-plan-final.json" model cost
  provider="$(jq -r '[.reviewers[].provider] | join("+")' "$plan" 2>/dev/null)"
  model="$(jq -r '[.reviewers[] | (.provider + "/" + (.model // .provider))] | join(" + ")' "$plan" 2>/dev/null)"
  cost="$(jq '[.reviewers[].costUsd // 0] | add // 0' "$plan" 2>/dev/null)"

  diff_split_findings "$work/norm.json" "$work/addr.json" "$work/split.json"
  local event requested_event author
  requested_event="$(findings_verdict "$work/norm.json")"
  author="$(jq -r '.author // ""' "$work/pr.json" 2>/dev/null)"
  event="$(findings_review_event "$work/norm.json" "$author" "$GOBLIN_LOGIN")"
  if [ "$event" != "$requested_event" ]; then
    log "  #$pr: PR is authored by @$author — posting findings as COMMENT, not $requested_event"
  fi
  render_review_body "$work/norm.json" "$work/split.json" "$pr" "$head" "$base" \
                     "$provider" "$model" "$GOBLIN_LOGIN" "$work/files.json" "$event" "$plan" > "$work/body.md"
  if ! post_build_review "$work/split.json" "$work/body.md" "$head" "$event" \
                         "$provider" "$model" "$pr" "$work/review.json"; then
    events_append failed "$pr" "$title" "$url" "$cost" "payload incomplete" "$slug" "$provider" "$model"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — review payload was incomplete"
    gh_status "$slug" "$head" error "review payload was incomplete"
    attempt_record "${slug}#${pr}:${head}" "payload"
    engine_pass_write "the review payload was incomplete" 0 "$head"
    return 1
  fi

  # Second liveness check. The model run above takes a minute or two, which is
  # long enough on this repo for the PR to merge underneath us.
  if ! gh_pr_is_open "$slug" "$pr"; then
    log "  #$pr: merged or closed during the review — not posting"
    ledger_add "${slug}#${pr}:${head}"
    status_set '{"state":"idle","activity":""}'
    engine_pass_write "the PR merged or closed during the review" 0 "$head"
    return 0
  fi

  local review_url
  if ! review_url="$(post_review "$slug" "$pr" "$work/review.json" "$work/err.json")"; then
    log "  #$pr: posting failed — $(head -c 200 "$work/err.json" 2>/dev/null)"
    rm -rf "$GOBLIN_HOME/last-failure"
    cp -R "$work" "$GOBLIN_HOME/last-failure" 2>/dev/null \
      && log "  #$pr: failed payload kept at $GOBLIN_HOME/last-failure"
    events_append failed "$pr" "$title" "$url" "$cost" "post failed" "$slug" "$provider" "$model"
    notify failed "$GOBLIN_NAME failed ⚠️" "#$pr — could not post review"
    gh_status "$slug" "$head" error "could not post review"
    attempt_record "${slug}#${pr}:${head}" "post"
    engine_pass_write "the review could not be posted" 0 "$head"
    return 1
  fi

  # the second comment: does this do what the ticket asked?
  local intent; intent="$(jq -c '.intent_note // empty' "$work/norm.json" 2>/dev/null)"
  if [ -n "$intent" ] && [ "$(printf '%s' "$intent" | jq -r '.verdict')" != "no_ticket" ]; then
    render_intent_body "$intent" "$pr" "$head" "$provider" "$model" "$GOBLIN_LOGIN" > "$work/intent.md"
    post_intent "$slug" "$pr" "$work/intent.md"
  fi

  # tell prior threads that their finding is gone
  #
  # "Gone" is only meaningful if the code MOVED. A re-review of the SAME commit —
  # which every --force re-run is, and every sweep pass after the first —
  # deliberately drops the findings already posted before it reaches here, so
  # each of those threads looks resolved and would be told "no longer flagged"
  # about a bug still sitting on that exact line. No new commit, nothing fixed.
  if [ -s "$prior_json" ] && [ "$(jq 'length' "$prior_json")" != "0" ] \
     && [ "$last_sha" != "$head" ]; then
    jq -c '[.findings[].id]' "$work/norm.json" > "$work/curids.json"
    post_fixed_replies "$slug" "$pr" "$prior_json" "$work/curids.json" "$head"
  fi

  local counts inline_n
  counts="$(render_counts "$work/norm.json")"
  inline_n="$(jq '.inline | length' "$work/split.json")"
  gh_status "$slug" "$head" success "$counts · $model" "$review_url"

  ledger_add "${slug}#${pr}:${head}"
  attempt_clear "${slug}#${pr}:${head}"
  # What a sweep converges on: the findings NEW in this review, after the ones
  # already posted on the PR were dropped above. The ids matter more than the
  # count — the sweep ends when a pass carries no id it has not already seen,
  # which is the only way a finding GitHub never anchored inline stops being
  # re-raised forever.
  engine_pass_write posted \
    "$(jq '.findings | length' "$work/norm.json" 2>/dev/null || echo 0)" "$head" \
    "$(jq -c '[.findings[].id]' "$work/norm.json" 2>/dev/null || echo '[]')"
  events_append posted "$pr" "$title" "$url" "$cost" "" "$slug" "$provider" "$model"
  # The moment the posted event exists, today_review_count sees it — holding
  # the reservation any longer double-counts this same review as both
  # reserved AND posted, which can refuse a concurrent audit that is actually
  # still under the real cap. The loop/trap release later is a no-op safety
  # net for every path that returns before this point, not the primary one.
  reservation_release
  REVIEWS_THIS_RUN=$((REVIEWS_THIS_RUN + 1))
  log "  #$pr: posted — $counts ($inline_n inline)${cost:+, \$$cost}"
  notify posted "$GOBLIN_NAME posted ✅" "#$pr — $counts"
  status_set '{"state":"idle","activity":""}'
  return 0
}

engine_dry_run() {
  local work="$1" slug="$2" pr="$3" head="$4" base="$5" provider="$6"
  local contributor reviewers
  contributor="$(jq -r 'if .contributor.detected then .contributor.label else "none detected" end' "$work/review-plan.json")"
  reviewers="$(jq -r '[.reviewers[].label] | join(" + ")' "$work/review-plan.json")"
  echo
  echo "── dry run: $slug#$pr @ $(trunc "$head" 7) ────────────────────"
  echo "coding agent:      $contributor"
  echo "reviewers:         $reviewers (parallel)"
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
    if [ -n "$ONLY_PR" ]; then log "  cloning isolated checkout for $slug#$pr"
    else log "  cloning $slug (one-time)"
    fi
    rm -rf "$dir"
    git clone --quiet "https://github.com/$slug.git" "$dir" >/dev/null 2>&1 || return 1
  fi
  git -C "$dir" fetch --quiet origin >/dev/null 2>&1 || return 1
  git -C "$dir" reset --hard --quiet >/dev/null 2>&1
  git -C "$dir" clean -ffd >/dev/null 2>&1
  ( cd "$dir" && gh pr checkout "$pr" --repo "$slug" --detach >/dev/null 2>&1 ) || return 1
  return 0
}
