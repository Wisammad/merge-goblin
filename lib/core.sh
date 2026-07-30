#!/usr/bin/env bash
# core.sh — logging, time, notifications, and the timeout watchdog.
# Written for bash 3.2 (what /bin/bash on macOS actually is): no associative
# arrays, no mapfile, no ${var,,}.

# launchd hands us a minimal PATH. Include the usual homes for user-installed
# CLIs (claude lives in ~/.local/bin, codex in /opt/homebrew/bin).
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$HOME/bin:$PATH"

now_epoch()      { date +%s; }
midnight_epoch() { date -v0H -v0M -v0S +%s; }
tomorrow_epoch() { date -v+1d -v0H -v0M -v0S +%s; }
week_ago_epoch() { echo $(( $(date +%s) - 604800 )); }

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

# Send all further output to the log file, rotating first.
log_open() {
  if [ -f "$LOG" ] && [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 4000 ]; then
    tail -n 1500 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
  exec >> "$LOG" 2>&1
}

die() { log "FATAL: $*"; exit 1; }

# notify <type> <title> <message> — gated on config notify.<type>.
notify() {
  local type="$1" title="$2" message="$3" sound="true"
  if command -v cfg_get >/dev/null 2>&1; then
    [ "$(cfg_get ".notify.${type}" true)" = "true" ] || return 0
    sound="$(cfg_get '.notify.sound' true)"
  fi
  # The message carries attacker-controlled text — a PR title, from anyone who can
  # open a PR on a watched repo. It is passed as argv and read with `item of argv`,
  # never interpolated into the script source. Escaping only `"` (as this used to)
  # leaves a backslash free to close the string literal, so a title ending in `\`
  # turned the whole thing into an AppleScript syntax error and silently dropped
  # the notification — `|| true` meant nobody ever found out.
  local script='on run argv
  display notification (item 2 of argv) with title (item 1 of argv)'
  [ "$sound" = "true" ] && script="$script sound name \"Glass\""
  script="$script
end run"
  printf '%s' "$script" | osascript - "$title" "$message" >/dev/null 2>&1 || true
}

# run_with_timeout <secs> <cmd...>
# macOS ships no timeout(1)/gtimeout, and a hung model call would otherwise wedge
# the whole run until the 3h stale-lock sweep. Returns 124 on timeout, else the
# child's exit code.
run_with_timeout() {
  local secs="$1"; shift
  # `<&0` is load-bearing: POSIX says an asynchronous command's stdin is assigned
  # to /dev/null unless explicitly redirected, which would silently swallow a
  # prompt the caller piped in. This passes the caller's stdin through.
  "$@" <&0 &
  local child=$!
  (
    local waited=0
    while [ "$waited" -lt "$secs" ]; do
      kill -0 "$child" 2>/dev/null || exit 0
      sleep 1
      waited=$((waited + 1))
    done
    # grace, then force
    kill -TERM "$child" 2>/dev/null
    sleep 5
    kill -KILL "$child" 2>/dev/null
  ) &
  local watcher=$!
  local rc=0
  wait "$child" 2>/dev/null || rc=$?
  # If the watcher already exited, the child finished on its own.
  if kill -0 "$watcher" 2>/dev/null; then
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null || true
  else
    [ "$rc" -ne 0 ] && rc=124
  fi
  return "$rc"
}

# Single-instance lock. Stale after 3h (a review can legitimately take minutes).
lock_acquire() {
  if [ -d "$LOCKDIR" ]; then
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
      log "removing stale lock"
      rmdir "$LOCKDIR" 2>/dev/null || rm -rf "$LOCKDIR"
    else
      return 1
    fi
  fi
  mkdir "$LOCKDIR" 2>/dev/null || return 1
  return 0
}
lock_release() { rmdir "$LOCKDIR" 2>/dev/null || true; }

# Stable short hash of a string (used for finding ids and fleet assignment).
goblin_hash() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12; }

# Portable lowercase (bash 3.2 has no ${x,,}).
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Truncate a string to N chars.
trunc() { printf '%s' "$1" | cut -c "1-$2"; }
