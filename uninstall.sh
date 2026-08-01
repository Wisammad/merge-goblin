#!/usr/bin/env bash
#
# uninstall.sh — send the Goblin home. Keeps your state unless you ask otherwise.
#
#   ./uninstall.sh            remove the app, scheduler and panel; keep history
#   ./uninstall.sh --purge    also delete config, history and scratch clones

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SRC/lib/brand.sh"
GOBLIN_HOME="${GOBLIN_HOME:-$HOME/.$GOBLIN_SLUG}"
export GOBLIN_HOME GOBLIN_APP="$GOBLIN_HOME/app"
[ -f "$GOBLIN_APP/lib/paths.sh" ] && SRC="$GOBLIN_APP"
. "$SRC/lib/paths.sh"; . "$SRC/lib/core.sh" 2>/dev/null; . "$SRC/lib/agent.sh"

PURGE=false
[ "${1:-}" = "--purge" ] && PURGE=true

printf '\n  removing %s\n\n' "$GOBLIN_NAME"

# scheduler: bootout AND clear the persistent disable override, so a later
# reinstall isn't silently dead on arrival.
if [ -f "$AGENT_PLIST" ] || launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
  agent_stop
  launchctl enable "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null || true
  rm -f "$AGENT_PLIST"
  echo "  ✓ scheduler removed"
fi

# The menu bar app owns a SECOND launch agent — its "start at login" item, whose
# label is the bundle id and not AGENT_LABEL. Removing only the review scheduler
# above left that one loaded, so the bar kept relaunching an app whose bundle had
# just been deleted. app_remove takes both down together.
if [ -f "$SRC/lib/app.sh" ]; then
  # shellcheck source=lib/app.sh
  . "$SRC/lib/app.sh"
  app_remove && echo "  ✓ menu bar app removed"
else
  rm -rf "$HOME/Applications/$GOBLIN_SHORT.app" 2>/dev/null && echo "  ✓ app removed"
fi

rm -f "$HOME/.local/bin/$GOBLIN_SLUG" 2>/dev/null && echo "  ✓ cli unlinked"
rm -rf "$GOBLIN_HOME/app" 2>/dev/null && echo "  ✓ app removed"

if [ "$PURGE" = true ]; then
  rm -rf "$GOBLIN_HOME"
  echo "  ✓ all state deleted ($GOBLIN_HOME)"
else
  cat <<EOF

  your history and config are still at $GOBLIN_HOME
    config.json · events.jsonl · ledger · repos/
  delete them with:  ./uninstall.sh --purge   (or: rm -rf $GOBLIN_HOME)
EOF
fi
printf '\n'
