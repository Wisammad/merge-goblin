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
  local dir="${1:-$LOCKDIR}"
  if [ -d "$dir" ]; then
    if [ -n "$(find "$dir" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
      log "removing stale lock"
      rmdir "$dir" 2>/dev/null || rm -rf "$dir"
    else
      return 1
    fi
  fi
  mkdir "$dir" 2>/dev/null || return 1
  return 0
}
lock_release() { rmdir "${1:-$LOCKDIR}" 2>/dev/null || true; }

# Exact-PR audits can run together, but never twice for the same PR. The global
# run lock still serializes scheduled and repo-wide scans.
PR_LOCKDIR=""
pr_lock_acquire() {
  local dir="$PR_LOCKS_DIR/$(goblin_hash "$1#$2")"
  lock_acquire "$dir" || return 1
  PR_LOCKDIR="$dir"
}
pr_lock_release() {
  [ -n "$PR_LOCKDIR" ] && lock_release "$PR_LOCKDIR"
  PR_LOCKDIR=""
}

# Stable short hash of a string (used for finding ids and fleet assignment).
goblin_hash() { printf '%s' "$1" | shasum -a 256 2>/dev/null | cut -c1-12; }

# goblin_state_lock <name> / goblin_state_unlock <name> — a brief mutual-exclusion
# lock around one shared state file's read-modify-write cycle.
#
# Exact-PR audits deliberately run concurrently now (see pr_lock_acquire above),
# but every audit still reads-then-writes process-wide files — attempts.json,
# status.json, update.json — through a fixed temp path. An atomic rename alone
# does not protect a read-modify-write: two audits can both read the file before
# either writes, and whichever renames last wins with a snapshot that never saw
# the other's update, silently dropping it (e.g. one PR's failure backoff).
# Held only around the write itself, never around a whole review.
#
# CONTRACT: goblin_state_lock returns 1 after ~10s of contention without ever
# acquiring the directory. Every caller MUST check that return value and only
# call goblin_state_unlock when it was true — unlock is an unconditional
# rmdir, so unlocking after a failed acquire releases the OTHER process's
# lock while it is still mid-write, letting a third process in behind it. The
# idiom every call site here uses:
#   local locked=false; goblin_state_lock NAME && locked=true
#   ...
#   [ "$locked" = true ] && goblin_state_unlock NAME
goblin_state_lock() {
  local dir="$STATE_LOCKS_DIR/$(goblin_hash "$1")" tries=0
  mkdir -p "$STATE_LOCKS_DIR" 2>/dev/null
  while ! lock_acquire "$dir"; do
    tries=$((tries + 1))
    # ~10s of real contention is not a healthy lock; proceed unlocked rather
    # than hang a review forever over a state file.
    [ "$tries" -ge 100 ] && return 1
    sleep 0.1
  done
}
goblin_state_unlock() { lock_release "$STATE_LOCKS_DIR/$(goblin_hash "$1")"; }

# atomic_write <dest> — write stdin to dest via a temp file in the same directory.
#
# The menu bar app watches these files and re-reads on every change, so a reader
# can arrive mid-write. A plain redirect truncates first, which means the app
# reliably sees a zero-byte or half-written JSON file and renders an empty panel.
# The empty check matters as much as the rename: a jq program that failed leaves
# nothing on stdout, and replacing good state with an empty file is worse than
# keeping the stale copy.
atomic_write() {
  local dest="$1" tmp rc
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  cat > "$tmp"; rc=$?
  if [ "$rc" -eq 0 ] && [ -s "$tmp" ]; then
    mv -f "$tmp" "$dest" && return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# Portable lowercase (bash 3.2 has no ${x,,}).
lc() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Truncate a string to N chars.
trunc() { printf '%s' "$1" | cut -c "1-$2"; }
