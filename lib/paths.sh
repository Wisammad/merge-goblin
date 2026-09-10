#!/usr/bin/env bash
# paths.sh — where everything lives. No absolute user paths anywhere.

# State/config home. Override with GOBLIN_HOME (tests use a temp dir).
#
# BOB_HOME/BOB_APP are honoured as fallbacks purely so an already-loaded launchd
# plist from a pre-rename install keeps working until `goblin agent install`
# rewrites it. Nothing else should read them; they go away in a later release.
GOBLIN_HOME="${GOBLIN_HOME:-${BOB_HOME:-$HOME/.$GOBLIN_SLUG}}"

CONFIG="$GOBLIN_HOME/config.json"
STATUS="$GOBLIN_HOME/status.json"
UISTATE="$GOBLIN_HOME/uistate.json"
EVENTS="$GOBLIN_HOME/events.jsonl"
LEDGER="$GOBLIN_HOME/ledger"            # "<repo>#<pr>:<headSha>" lines, one per reviewed commit
LOG="$GOBLIN_HOME/$GOBLIN_SLUG.log"
UIURL="$GOBLIN_HOME/ui.url"             # where a running control panel is listening
UPDATE_STATE="$GOBLIN_HOME/update.json" # last version check; see update.sh
INBOX="$GOBLIN_HOME/inbox.json"         # waiting-PR counts for the menu bar; see inbox.sh
RESERVATIONS="$GOBLIN_HOME/reservations.json" # in-flight review slots; see state.sh
LOCKDIR="$GOBLIN_HOME/.lock"
PR_LOCKS_DIR="$GOBLIN_HOME/pr-locks"
STATE_LOCKS_DIR="$GOBLIN_HOME/state-locks"  # brief per-file locks; see goblin_state_lock
REPOS_DIR="$GOBLIN_HOME/repos"          # scratch clones: repos/<owner>__<name>
RUNTMP="$GOBLIN_HOME/tmp"

# GOBLIN_APP is the installed copy of the application (bin/ lib/ share/ templates/).
# install.sh copies the repo here deliberately: launchd cannot read ~/Documents
# and friends under macOS TCC, so the runtime must live somewhere it can reach.
# When running straight from a git checkout, GOBLIN_APP is that checkout.
if [ -z "${GOBLIN_APP:-}" ] && [ -n "${BOB_APP:-}" ]; then
  GOBLIN_APP="$BOB_APP"          # pre-rename plist; see the GOBLIN_HOME note above
fi
if [ -z "${GOBLIN_APP:-}" ]; then
  _goblin_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  GOBLIN_APP="$(cd "$_goblin_lib_dir/.." && pwd)"
fi
LIB_DIR="$GOBLIN_APP/lib"
SHARE_DIR="$GOBLIN_APP/share"
TEMPLATE_DIR="$GOBLIN_APP/templates"
PROVIDER_DIR="$LIB_DIR/providers"

SCHEMA_FILE="$SHARE_DIR/schema/findings.schema.json"

# launchd label is per-user so two accounts on one Mac never collide, and so it
# is never someone else's hardcoded "com.kiril.*".
goblin_agent_label() {
  local u; u="$(id -un 2>/dev/null | tr -cd '[:alnum:]._-')"
  printf 'com.%s.%s' "${u:-user}" "$GOBLIN_SLUG"
}
AGENT_LABEL="$(goblin_agent_label)"
AGENT_PLIST="$HOME/Library/LaunchAgents/${AGENT_LABEL}.plist"


goblin_ensure_dirs() {
  mkdir -p "$GOBLIN_HOME" "$PR_LOCKS_DIR" "$STATE_LOCKS_DIR" "$REPOS_DIR" "$RUNTMP" 2>/dev/null || true
  # 700, not 755: this directory holds PR titles, spend history and raw model
  # output under last-failure/. On a shared Mac every other user could read it.
  chmod 700 "$GOBLIN_HOME" 2>/dev/null || true
}

# Sweep abandoned run scratch out of RUNTMP.
#
# Nothing else ever does: a run deletes its own scratch through a trap on
# EXIT/INT/TERM, so a SIGKILL, a crash, or a laptop that sleeps mid-review leaks
# the whole directory permanently. Measured 2026-09-10: 108MB across 529 entries
# reaching back a month, including one abandoned 84MB checkout and 508 stale
# meta-*.json. There is no `goblin clean`, so it only ever grew.
#
# Age is the safe test, not PID ownership. A live run's scratch is seconds old and
# a concurrent fanout worker's is minutes old, so anything older than a day belongs
# to a run that is definitively gone — which also makes this safe to call while
# other goblins are running. Tune with: goblin config set .tmpRetentionDays N
goblin_tmp_gc() {
  # At most one sweep per process: the run entry points overlap (a pasted link
  # goes through cmd_url and then cmd_run), so calling this twice must be free.
  [ -n "${GOBLIN_TMP_GC_DONE:-}" ] && return 0
  GOBLIN_TMP_GC_DONE=1
  [ -d "$RUNTMP" ] || return 0
  local days; days="$(cfg_get '.tmpRetentionDays' 2)"
  case "$days" in ''|*[!0-9]*) days=2 ;; esac
  [ "$days" -lt 1 ] && days=1
  find "$RUNTMP" -mindepth 1 -maxdepth 1 -mtime "+$days" -exec rm -rf {} + 2>/dev/null || true
}

# Scratch clone path for an owner/name slug.
goblin_repo_dir() {
  printf '%s/%s' "$REPOS_DIR" "$(printf '%s' "$1" | tr '/' '_' | tr -cd '[:alnum:]._-')"
}
