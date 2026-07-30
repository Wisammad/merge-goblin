#!/usr/bin/env bash
#
# install.sh — put the Merge Goblin on duty. Safe to re-run; that's the upgrade path.
#
#   ./install.sh                       interactive
#   ./install.sh --non-interactive     accept all defaults
#   ./install.sh --no-agent            don't schedule it
#   ./install.sh --no-app              skip the control panel app
#   ./install.sh --home <dir>          state somewhere other than ~/.goblin

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SRC/lib/brand.sh"

INTERACTIVE=true; WITH_AGENT=true; WITH_MENU=true
GOBLIN_HOME="${GOBLIN_HOME:-$HOME/.$GOBLIN_SLUG}"
while [ $# -gt 0 ]; do
  case "$1" in
    --non-interactive|-y) INTERACTIVE=false; shift ;;
    --no-agent) WITH_AGENT=false; shift ;;
    --no-menu|--no-app) WITH_MENU=false; shift ;;
    --home)     GOBLIN_HOME="$2"; shift 2 ;;
    -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

# The app is installed into GOBLIN_HOME/app rather than run from the clone: launchd
# cannot read ~/Documents, ~/Desktop and friends under macOS TCC, so a checkout
# there would work by hand and silently fail on a schedule.
APP="$GOBLIN_HOME/app"
export GOBLIN_HOME GOBLIN_APP="$APP"

say()  { printf '%s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$*"; }
ask() { # ask <prompt> <default>
  [ "$INTERACTIVE" = false ] && { printf '%s' "$2"; return; }
  local a; printf '%s [%s]: ' "$1" "$2" > /dev/tty; read -r a < /dev/tty || true
  printf '%s' "${a:-$2}"
}

printf '\n  %s — %s\n  installing to %s\n\n' "$GOBLIN_NAME" "$GOBLIN_TAGLINE" "$GOBLIN_HOME"

# --- 1. dependencies ------------------------------------------------------
say "dependencies"
missing=""
for c in gh jq git; do
  if command -v "$c" >/dev/null 2>&1; then ok "$c"; else err "$c missing"; missing="$missing $c"; fi
done
if [ -n "$missing" ]; then
  err "install first:  brew install$missing"
  exit 1
fi
if ! gh auth status >/dev/null 2>&1; then
  err "gh is not logged in — run: gh auth login"
  exit 1
fi

# --- 2. an AI provider ----------------------------------------------------
say ""; say "ai providers (the Goblin uses a subscription you already have)"
found=""
command -v claude       >/dev/null 2>&1 && { ok "claude";       found="$found claude"; }
command -v codex        >/dev/null 2>&1 && { ok "codex";        found="$found codex"; }
command -v cursor-agent >/dev/null 2>&1 && { ok "cursor-agent"; found="$found cursor"; }
if [ -z "$found" ]; then
  err "no AI CLI found. install at least one:"
  say  "      claude  →  https://claude.ai/code"
  say  "      codex   →  npm i -g @openai/codex   (then: codex login)"
  say  "      cursor  →  curl https://cursor.com/install -fsS | bash"
  exit 1
fi
DEFAULT_PROVIDER="$(printf '%s' "$found" | awk '{print $1}')"

# --- 3. copy the app ------------------------------------------------------
say ""; say "installing"
mkdir -p "$GOBLIN_HOME" "$APP" || { err "cannot create $GOBLIN_HOME"; exit 1; }
# ${APP:?} so an empty APP can never turn this into `rm -rf /lib`.
rm -rf "${APP:?}/lib" "${APP:?}/bin" "${APP:?}/share" "${APP:?}/templates"
cp -R "$SRC/lib" "$SRC/bin" "$SRC/share" "$SRC/templates" "$APP/" 2>/dev/null
chmod +x "$APP/bin/$GOBLIN_SLUG"
ok "app  → $APP"

# CLI on PATH. ~/.local/bin doesn't need sudo and is on modern macOS PATHs.
BINDIR="$HOME/.local/bin"; mkdir -p "$BINDIR"
ln -sf "$APP/bin/$GOBLIN_SLUG" "$BINDIR/$GOBLIN_SLUG"
ok "cli  → $BINDIR/$GOBLIN_SLUG"
case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) warn "$BINDIR is not on your PATH — add to ~/.zshrc:"
     say  "        export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# --- 4. config ------------------------------------------------------------
. "$APP/lib/paths.sh"; . "$APP/lib/core.sh"; . "$APP/lib/config.sh"
. "$APP/lib/agent.sh"; . "$APP/lib/state.sh"
cfg_ensure; cfg_backfill_defaults

say ""; say "configuration"
CUR_LOGIN="$(cfg_get '.identity.githubLogin' '')"
[ -z "$CUR_LOGIN" ] && CUR_LOGIN="$(gh api user --jq .login 2>/dev/null)"
LOGIN="$(ask "  github login to review as" "$CUR_LOGIN")"
cfg_set --arg l "$LOGIN" '.identity.githubLogin = $l'
ok "reviewing as @$LOGIN"

PROVIDER="$(ask "  which subscription should review" "$(cfg_get '.provider' "$DEFAULT_PROVIDER")")"
cfg_set --arg p "$PROVIDER" '.provider = $p'
ok "provider: $PROVIDER"

if [ -z "$(cfg_repos_enabled)" ]; then
  GUESS=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    GUESS="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  fi
  REPO="$(ask "  repo to watch (owner/name, blank to skip)" "$GUESS")"
  [ -n "$REPO" ] && { cfg_repo_add "$REPO"; ok "watching $REPO"; }
fi

# --- 5. migrate -----------------------------------------------------------
if [ -f "$HOME/conductor/prauto.config.json" ] && [ ! -f "$GOBLIN_HOME/.migrated" ]; then
  say ""
  if [ "$(ask "  import history from the old prauto setup? (y/n)" y)" = "y" ]; then
    "$APP/bin/$GOBLIN_SLUG" migrate || true
  fi
fi

# --- 6. scheduler ---------------------------------------------------------
if [ "$WITH_AGENT" = true ]; then
  say ""; say "scheduler"
  INTERVAL="$(cfg_get '.intervalSeconds' 300)"
  mkdir -p "$HOME/Library/LaunchAgents"
  sed -e "s|__LABEL__|$AGENT_LABEL|g" \
      -e "s|__CLI__|$APP/bin/$GOBLIN_SLUG|g" \
      -e "s|__GOBLIN_HOME__|$GOBLIN_HOME|g" \
      -e "s|__GOBLIN_APP__|$APP|g" \
      -e "s|__INTERVAL__|$INTERVAL|g" \
      "$APP/templates/launchd.plist.tmpl" > "$AGENT_PLIST"
  if plutil -lint "$AGENT_PLIST" >/dev/null 2>&1; then
    agent_stop; agent_on
    if agent_running; then ok "scheduled every ${INTERVAL}s ($AGENT_LABEL)"
    else warn "plist written but the agent didn't load — run: $GOBLIN_SLUG agent start"; fi
  else
    err "generated plist is invalid: $AGENT_PLIST"
  fi
fi

# --- 7. control panel -----------------------------------------------------
# A tiny .app whose only job is to launch `$GOBLIN_SLUG ui`, so the panel is in Spotlight
# and the Dock like any other app. It's a script bundle built locally, so there
# is nothing to sign, notarise or approve in Gatekeeper.
if [ "$WITH_MENU" = true ]; then
  say ""; say "control panel"
  APPDIR="$HOME/Applications/$GOBLIN_SHORT.app"
  mkdir -p "$APPDIR/Contents/MacOS" "$APPDIR/Contents/Resources"
  cp "$APP/share/ui/goblin.icns" "$APPDIR/Contents/Resources/goblin.icns" 2>/dev/null
  cat > "$APPDIR/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$GOBLIN_NAME</string>
  <key>CFBundleDisplayName</key><string>$GOBLIN_NAME</string>
  <key>CFBundleIdentifier</key><string>com.$(id -un | tr -cd '[:alnum:]').$GOBLIN_SLUG</string>
  <key>CFBundleVersion</key><string>$GOBLIN_VERSION</string>
  <key>CFBundleShortVersionString</key><string>$GOBLIN_VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>$GOBLIN_SLUG-panel</string>
  <key>CFBundleIconFile</key><string>goblin</string>
</dict>
</plist>
PLIST
  cat > "$APPDIR/Contents/MacOS/$GOBLIN_SLUG-panel" <<LAUNCH
#!/bin/bash
# Opens the control panel in your browser and keeps serving it until this app is
# quit. Running it twice just re-opens the tab rather than starting a second one.
export GOBLIN_HOME="$GOBLIN_HOME"
exec "$APP/bin/$GOBLIN_SLUG" ui
LAUNCH
  chmod +x "$APPDIR/Contents/MacOS/$GOBLIN_SLUG-panel"
  ok "app  → $APPDIR"
  say  "        double-click it, or run: $GOBLIN_SLUG ui"
  say  "        (quit the app, or '$GOBLIN_SLUG ui --stop', to shut the panel down)"
fi

# --- 8. checkup -----------------------------------------------------------
say ""
"$APP/bin/$GOBLIN_SLUG" doctor || true

cat <<EOF

  $GOBLIN_EMOJI  $GOBLIN_NAME is on duty.

    $GOBLIN_SLUG ui             open the control panel — everything is in there
    $GOBLIN_SLUG status         where things stand
    $GOBLIN_SLUG run --plan     dry run: see what it would post, post nothing
    $GOBLIN_SLUG off / $GOBLIN_SLUG on   master switch
    $GOBLIN_SLUG doctor         diagnose anything odd

  $GOBLIN_NAME reviews as @$LOGIN using your $PROVIDER subscription, posts one
  clearly-labelled automated review per PR, and never approves or blocks.

EOF
