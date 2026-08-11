#!/usr/bin/env bash
# attempts.sh — per-commit failure backoff.
#
# Why this exists: a failing review used to cost two model calls, write nothing to
# the ledger, and not count against any limit. So N PRs that fail — a diff the
# model chokes on, a provider that is signed out, an oversized PR — were retried
# every interval, forever, at full price, with a notification each time.
#
# State lives in ~/.goblin/attempts.json, keyed "<repo>#<pr>:<headSha>".
# The two-argument form remains for state written by older installs.
#
# Keying on the head sha means a new push resets the counter for free: the key
# simply does not exist yet. That is the behaviour you want — a push is exactly
# the event most likely to fix whatever broke.
#
# THIS FILE IS A MOVE, NOT A REWRITE. The three functions below were inline in
# engine.sh and are unchanged, because the file they own is live on every install
# and two shapes written by two writers would corrupt it. They moved out because
# two readers need them and neither can afford to source engine.sh (which pulls in
# providers, findings, github, render, post, claim, prompt and diff):
#
#   * inbox.sh, to explain why a PR the panel lists is not being reviewed
#   * state.sh, to publish the stuck list the menu bar's glyph depends on
#
# attempt_reason and attempt_stuck_json are the only additions; both are readers.

attempt_file() { printf '%s/attempts.json' "$GOBLIN_HOME"; }

# The one place the key shape is written down. engine.sh and the panel disagreed
# about it once, which meant the panel reported nothing blocked while the engine
# was backing off every PR.
attempt_key() {
  if [ "$#" -ge 3 ]; then
    if [ -n "$1" ]; then printf '%s#%s:%s' "$1" "$2" "$3"
    else printf '%s:%s' "$2" "$3"
    fi
  else
    printf '%s:%s' "$1" "$2"
  fi
}

# `key` is always the current "repo#pr:head" shape (see attempt_key), but an
# install upgraded from before repo-scoping can have an active backoff filed
# under the pre-migration "pr:head" shape. ledger_reviewed already reads both
# shapes (state.sh); this did not, so after an upgrade an in-flight backoff
# under the old key was invisible and the head it was protecting got retried
# immediately instead of waiting out its delay.
attempt_blocked() {
  local key="$1" f; f="$(attempt_file)"
  [ -f "$f" ] || return 1
  local legacy="${key#*#}"
  local next; next="$(jq -r --arg k "$key" --arg k2 "$legacy" \
    '[.[$k].nextAt, .[$k2].nextAt] | map(select(. != null)) | max // 0' "$f" 2>/dev/null)"
  [ "${next:-0}" = "null" ] && next=0
  [ "$(now_epoch)" -lt "${next:-0}" ] 2>/dev/null
}

attempt_record() {
  local key="$1" kind="${2:-other}" f; f="$(attempt_file)"
  goblin_state_lock attempts
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
  goblin_state_unlock attempts
  [ "$delay" -gt 0 ] && log "  #${key%%:*}: $n consecutive failures — holding this commit for $((delay / 60))m"
  return 0
}

attempt_clear() {
  local key="$1" f; f="$(attempt_file)"
  [ -f "$f" ] || return 0
  local legacy="${key#*#}"
  goblin_state_lock attempts
  jq --arg k "$key" --arg k2 "$legacy" 'del(.[$k], .[$k2])' "$f" > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
  goblin_state_unlock attempts
}

# attempt_reason <key> — one human-readable line for the panel.
#
# The panel's job here is to answer "why is this PR just sitting there", and
# "3 failed attempts (bad_output), next try 14:20" is the only answer that stops
# someone concluding the Goblin is broken and switching it off.
attempt_reason() {
  local key="$1" f; f="$(attempt_file)"
  [ -f "$f" ] || return 0
  local n kind next when=""
  n="$(jq -r --arg k "$key" '.[$k].n // 0' "$f" 2>/dev/null)"
  kind="$(jq -r --arg k "$key" '.[$k].kind // ""' "$f" 2>/dev/null)"
  next="$(jq -r --arg k "$key" '.[$k].nextAt // 0' "$f" 2>/dev/null)"
  case "$n" in ''|null|*[!0-9]*) return 0 ;; esac
  [ "$n" -gt 0 ] || return 0
  case "$next" in ''|null|*[!0-9]*) next=0 ;; esac
  [ "$next" -gt "$(now_epoch)" ] && when=", next try $(date -r "$next" '+%H:%M')"
  case "$kind" in ''|null) kind="" ;; *) kind=" ($kind)" ;; esac
  printf '%s failed attempt(s)%s%s' "$n" "$kind" "$when"
}

# attempt_stuck_json — PRs that have burned every attempt and are waiting out a
# backoff. Published into the UI state so the menu bar glyph can go red: a PR that
# will not be retried for hours is exactly the failure a human must know about,
# and it is otherwise invisible unless someone goes and reads the log.
attempt_stuck_json() {
  local f; f="$(attempt_file)"
  [ -f "$f" ] || { printf '[]'; return 0; }
  local maxa out; maxa="$(cfg_get '.failure.maxAttempts' 3)"
  out="$(jq -c --argjson now "$(now_epoch)" --argjson maxa "${maxa:-3}" '
    [ to_entries[]
      | select((.value.n // 0) >= $maxa)
      | select((.value.nextAt // 0) > $now)
      | { number: ((.key | split(":") | .[0] | split("#") | last | tonumber?) // 0),
          repo:   ((.key | split(":") | .[0] | split("#") | if length > 1 then .[0] else "" end)),
          head:   ((.key | split(":") | .[1]) // ""),
          n:      (.value.n // 0),
          kind:   (.value.kind // ""),
          nextAt: (.value.nextAt // 0) } ]
    | sort_by(-.n)' "$f" 2>/dev/null)"
  if [ -n "$out" ]; then printf '%s' "$out"; else printf '[]'; fi
}
