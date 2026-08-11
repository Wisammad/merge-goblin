#!/usr/bin/env bash
# cmd_panel.sh — the only settings surface the UI is allowed to touch.
#
# WHY THIS EXISTS. The old control panel could send `config set <jq-path> <value>`,
# which meant it could point `.providers.claude.bin` at any executable and then
# trigger a run — arbitrary code execution on a 15-minute schedule, reachable by
# anything that could reach the panel. Every setting now has its own named verb
# with its own validation, and there is deliberately NO general config setter here.
#
# Defence in depth, three independent layers:
#   1. the app's Swift Command enum, which cannot even express an arbitrary path
#   2. this file, which re-validates every value and maps it to a fixed cfg_set
#   3. provider_bin_resolve, which constrains binary paths at the point of USE, so
#      a hand-edited config.json is caught too
#
# Layer 2 exists because it is the one the offline test suite can exercise. If you
# add a setting, add a case — do not add a passthrough.

# _panel_int <value> <min> <max> — echo a clamped integer, or fail.
_panel_int() {
  local v="$1" lo="$2" hi="$3"
  case "$v" in ''|*[!0-9]*) return 1 ;; esac
  [ "$v" -lt "$lo" ] && return 1
  [ "$v" -gt "$hi" ] && return 1
  printf '%s' "$v"
}

_panel_bool() {
  case "$1" in true|1|on|yes) printf 'true' ;; false|0|off|no) printf 'false' ;; *) return 1 ;; esac
}

_panel_slug() {
  case "$1" in
    */*) ;;
    *) return 1 ;;
  esac
  # one slash, and only characters GitHub actually allows
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$' || return 1
  printf '%s' "$1"
}

_panel_login() {
  # Alnum or single hyphens, never leading/trailing — see install.sh: one login
  # rule, shared with app/Command.swift.
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$' || return 1
  printf '%s' "$1"
}

_panel_model() {
  # Empty is legitimate: it means "the provider default".
  [ -z "$1" ] && { printf ''; return 0; }
  printf '%s' "$1" | grep -qE '^[A-Za-z0-9._:-]{1,64}$' || return 1
  printf '%s' "$1"
}

_panel_provider() {
  case "$1" in claude|codex|cursor) printf '%s' "$1" ;; *) return 1 ;; esac
}

cmd_panel() {
  local sub="${1:-}"; shift 2>/dev/null || true
  case "$sub" in

    set) _panel_set "$@" ;;

    dry-run)
      # Detached, like run-now: a dry run can take a minute and must not hold the
      # UI open waiting for it.
      nohup "$GOBLIN_APP/bin/$GOBLIN_SLUG" run --plan >/dev/null 2>&1 &
      echo "dry run started" ;;

    *) echo "usage: $GOBLIN_SLUG panel set <key> <value> | $GOBLIN_SLUG panel dry-run" >&2
       return 2 ;;
  esac
}

_panel_set() {
  local key="${1:-}"; shift 2>/dev/null || true
  local v="${1:-}" v2="${2:-}" out

  case "$key" in
    max-per-day)
      out="$(_panel_int "$v" 0 500)"    || { echo "reviews per day must be 0-500" >&2; return 2; }
      cfg_set ".maxReviewsPerDay = $out" ;;
    max-per-run)
      out="$(_panel_int "$v" 1 50)"     || { echo "reviews per run must be 1-50" >&2; return 2; }
      cfg_set ".maxReviewsPerRun = $out" ;;
    max-findings)
      out="$(_panel_int "$v" 1 200)"    || { echo "findings must be 1-200" >&2; return 2; }
      cfg_set ".maxFindings = $out" ;;
    interval|interval-minutes)
      # Minutes in, seconds stored. The plist carries the interval, so changing it
      # only takes effect once the agent is rewritten — say so rather than lying.
      out="$(_panel_int "$v" 1 1440)"   || { echo "interval must be 1-1440 minutes" >&2; return 2; }
      cfg_set ".intervalSeconds = $((out * 60))"
      echo "interval saved — run '$GOBLIN_SLUG agent reload' (or reinstall) to apply it" ;;
    timeout)
      out="$(_panel_int "$v" 60 7200)"  || { echo "timeout must be 60-7200 seconds" >&2; return 2; }
      cfg_set ".timeoutSecs = $out" ;;
    diff-bytes)
      out="$(_panel_int "$v" 10000 4000000)" || { echo "diff bytes must be 10000-4000000" >&2; return 2; }
      cfg_set ".maxDiffBytes = $out" ;;

    verdict|verdict-mode)
      case "$v" in
        comment|request-changes|full) cfg_set --arg m "$v" '.verdictMode = $m' ;;
        *) echo "verdict must be comment, request-changes or full" >&2; return 2 ;;
      esac ;;
    allow-approve)
      out="$(_panel_bool "$v")" || { echo "expected a boolean" >&2; return 2; }
      # Approving under a human account needs BOTH this and verdictMode=full, on
      # purpose: two independent opt-ins for the one irreversible action.
      cfg_set ".allowApprove = $out" ;;

    flag)
      local fkey="$v" fval
      fval="$(_panel_bool "$v2")" || { echo "expected a boolean" >&2; return 2; }
      # BOTH spellings, and this is not cosmetic. The app sends the kebab-case CLI
      # spelling (`incremental-review`); this only matched camelCase, so every
      # toggle in the Behaviour and Notifications sections was silently refused and
      # clicking them did nothing at all. Each side had tests, and each side passed
      # — nothing tested the contract BETWEEN them, which is what the
      # panel-contract test now does.
      case "$fkey" in
        incremental-review|incrementalReview)     cfg_set ".incrementalReview = $fval" ;;
        post-commit-status|postCommitStatus)      cfg_set ".postCommitStatus = $fval" ;;
        fleet-assignment|fleetAssignment)         cfg_set ".fleetAssignment = $fval" ;;
        skip-if-human-reviewed|skipIfHumanReviewed) cfg_set ".skipIfHumanReviewed = $fval" ;;
        notify-started|notifyStarted) cfg_set ".notify.started = $fval" ;;
        notify-posted|notifyPosted)   cfg_set ".notify.posted  = $fval" ;;
        notify-failed|notifyFailed)   cfg_set ".notify.failed  = $fval" ;;
        notify-budget|notifyBudget)   cfg_set ".notify.budget  = $fval" ;;
        notify-sound|notifySound)     cfg_set ".notify.sound   = $fval" ;;
        *) echo "unknown flag '$fkey'" >&2; return 2 ;;
      esac ;;

    model|provider-model)
      local pid mdl
      pid="$(_panel_provider "$v")" || { echo "unknown provider" >&2; return 2; }
      mdl="$(_panel_model "$v2")"   || { echo "invalid model name" >&2; return 2; }
      cfg_set --arg p "$pid" --arg m "$mdl" '.providers[$p].model = $m' ;;

    identity)
      local l; l="$(_panel_login "$v")" || { echo "invalid github login" >&2; return 2; }
      cfg_set --arg l "$l" '.identity.githubLogin = $l' ;;

    repo-prompt)
      local s; s="$(_panel_slug "$v")" || { echo "invalid repo slug" >&2; return 2; }
      # A path, but never one that escapes the repo.
      case "$v2" in
        *..*|/*) echo "prompt path must be relative and must not contain .." >&2; return 2 ;;
      esac
      cfg_repo_set_field "$s" promptPath "$v2" ;;

    setup-complete)
      # Only ever set true from here. Turning setup "off" is not a thing the UI
      # should be able to do — it would silently stop every review.
      cfg_set '.setupComplete = true' ;;

    *)
      echo "unknown setting '$key'" >&2
      return 2 ;;
  esac

  status_set '{}'
}
