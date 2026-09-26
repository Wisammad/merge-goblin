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
# cursor-agent persists every run here; see goblin_cursor_chats_gc.
CURSOR_CHATS="${CURSOR_CHATS:-$HOME/.cursor/chats}"

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
  goblin_cursor_chats_gc
}

# Sweep cursor-agent chat transcripts left behind by finished reviews.
#
# cursor-agent persists every `-p` run to ~/.cursor/chats/<bucket>/<id>/ (a
# store.db plus a meta.json recording the run's cwd). It has no flag to disable
# or relocate that, and nothing in Cursor prunes it, so a goblin reviewing all
# day grows it forever. Measured 2026-09-17 on this machine: 686 of 703 chats
# were goblin's, 1.27GB, still growing ~70MB/day while the human had not opened
# Cursor in two weeks. RUNTMP was clean the whole time — this is the leak that
# goblin_tmp_gc cannot see, because it lands outside GOBLIN_HOME.
#
# Ownership and liveness both come from meta.json's cwd:
#   - not under GOBLIN_HOME      -> a human's own Cursor chat. Never touched.
#   - a scratch dir now GONE     -> the run's EXIT trap or goblin_tmp_gc already
#                                   reaped it, so that run is definitively over.
#   - a path that still EXISTS   -> either a live run or the shared clone under
#                                   repos/. Fall back to age so a shared-clone
#                                   chat cannot leak forever, but a live one is
#                                   far too young to match.
#
# Keying on "is the scratch still there" rather than a PID or a wall clock is
# what makes this safe during a parallel fanout: five loops sharing one clone
# each hold their own scratch dir for as long as they run, so none of their
# chats can be swept mid-review. GOBLIN_CHAT_GRACE_MIN covers the seconds
# between a run deleting its scratch and its last write to the chat.
goblin_cursor_chats_gc() {
  [ -d "$CURSOR_CHATS" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local days; days="$(cfg_get '.tmpRetentionDays' 2)"
  case "$days" in ''|*[!0-9]*) days=2 ;; esac
  [ "$days" -lt 1 ] && days=1

  local grace; grace="${GOBLIN_CHAT_GRACE_MIN:-60}"
  case "$grace" in ''|*[!0-9]*) grace=60 ;; esac

  local meta dir cwd
  while IFS= read -r meta; do
    [ -n "$meta" ] || continue
    dir="$(dirname "$meta")"
    cwd="$(jq -r '.cwd // ""' "$meta" 2>/dev/null)"
    # Only ever our own runs, and never the store root itself.
    case "$cwd" in "$GOBLIN_HOME"/?*) ;; *) continue ;; esac
    if [ -d "$cwd" ]; then
      find "$dir" -maxdepth 0 -mtime "+$days" -exec rm -rf {} + 2>/dev/null || true
    else
      rm -rf "$dir" 2>/dev/null || true
    fi
  done <<EOF
$(find "$CURSOR_CHATS" -mindepth 3 -maxdepth 3 -name meta.json -mmin "+$grace" 2>/dev/null)
EOF

  # Drop the bucket dirs that just lost their last chat.
  find "$CURSOR_CHATS" -mindepth 1 -maxdepth 1 -type d -empty -delete 2>/dev/null || true
}

# Scratch clone path for an owner/name slug.
goblin_repo_dir() {
  printf '%s/%s' "$REPOS_DIR" "$(printf '%s' "$1" | tr '/' '_' | tr -cd '[:alnum:]._-')"
}
