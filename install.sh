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
# Not every answer is free text, and the ones that aren't have to be caught HERE,
# while the person who typed them is still looking at the prompt. An email typed
# at the login prompt used to be stored verbatim and then surface, minutes later
# and three screens down, as "no stored token for 'you@example.com'" — a message
# about tokens for what is really a typo. Every other writer (lib/cmd_panel.sh,
# app/Command.swift) already enforces this shape; the installer was the hole.
ask_valid() { # ask_valid <regex> <complaint> <prompt> <default>
  local re="$1" complaint="$2" prompt="$3" def="$4" a
  while :; do
    a="$(ask "$prompt" "$def")"
    # '%s\n', not '%s': an empty answer must still reach grep as one empty LINE.
    # Printed bare it is zero bytes, grep sees no lines and matches nothing, and a
    # question that documents "blank to skip" re-asks itself until the tab is closed.
    printf '%s\n' "$a" | grep -qE "$re" && { printf '%s' "$a"; return 0; }
    # --non-interactive can't be re-asked, so it fails instead of storing junk.
    [ "$INTERACTIVE" = false ] && return 1
    printf '  \033[33m!\033[0m %s\n' "$complaint" > /dev/tty
  done
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
# app/ and app-tests/ come too: `goblin app rebuild` has to work from the INSTALLED
# copy, because the clone may be in ~/Documents where launchd cannot read it — and
# the whole reason the runtime lives here is that TCC restriction. Without the
# sources, app_build silently skipped and the installer reported success while
# installing no app at all.
# ${APP:?} so an empty APP can never turn this into `rm -rf /lib`.
rm -rf "${APP:?}/lib" "${APP:?}/bin" "${APP:?}/share" "${APP:?}/templates" \
       "${APP:?}/app" "${APP:?}/app-tests"
cp -R "$SRC/lib" "$SRC/bin" "$SRC/share" "$SRC/templates" \
      "$SRC/app" "$SRC/app-tests" "$APP/" 2>/dev/null
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
say "  the value in [brackets] is what you get if you just press return."

# Each question says what KIND of answer it wants, because the bracketed default
# alone doesn't: "github login to review as [Wisammad]" reads as a yes/no to
# someone seeing it once, and an email typed there used to sail straight through.
say ""
say "  · the github account the reviews are posted from."
say "       your github username — not an email, not a password."
CUR_LOGIN="$(cfg_get '.identity.githubLogin' '')"
[ -z "$CUR_LOGIN" ] && CUR_LOGIN="$(gh api user --jq .login 2>/dev/null)"
# A GitHub username is alphanumeric or single hyphens, and never starts or
# ends with one — ^[A-Za-z0-9-]{1,39}$ alone accepted "-owner", "owner-" and
# "owner--name", none of which GitHub allows, and none of which "not an email"
# ever caught. See lib/cmd_panel.sh and app/Command.swift: one login rule.
if ! LOGIN="$(ask_valid '^[A-Za-z0-9](-?[A-Za-z0-9]){0,38}$' \
      "a github username is letters, digits and single dashes, never leading/trailing — an email is not one" \
      "  github username" "$CUR_LOGIN")"; then
  err "'$CUR_LOGIN' is not a github username — set one and re-run:"
  say "        $GOBLIN_SLUG config set .identity.githubLogin <username>"
  exit 1
fi
cfg_set --arg l "$LOGIN" '.identity.githubLogin = $l'
ok "reviewing as @$LOGIN"

# `found` is what step 2 detected on this machine. Offering anything else is a
# trap: it saves fine and then fails doctor with "provider is not installed".
# The default was simply the first one detected, which explained nothing.
say ""
CHOICES="$(printf '%s' "$found" | xargs)"          # "claude codex"
say "  · the ai subscription that does the reviewing."
say "       installed on this machine: ${CHOICES// /, }"
CUR_PROVIDER="$(cfg_get '.provider' "$DEFAULT_PROVIDER")"
case " $CHOICES " in
  *" $CUR_PROVIDER "*) ;;
  *) CUR_PROVIDER="$DEFAULT_PROVIDER" ;;           # never default to one that's gone
esac
if ! PROVIDER="$(ask_valid "^($(printf '%s' "$CHOICES" | tr ' ' '|'))\$" \
      "pick one of: ${CHOICES// /, }" \
      "  provider (${CHOICES// / or })" "$CUR_PROVIDER")"; then
  err "'$CUR_PROVIDER' is not installed here — pick one of: ${CHOICES// /, }"
  exit 1
fi
cfg_set --arg p "$PROVIDER" '.provider = $p'
ok "provider: $PROVIDER"

if [ -z "$(cfg_repos_enabled)" ]; then
  GUESS=""
  if git rev-parse --git-dir >/dev/null 2>&1; then
    GUESS="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  fi
  say ""
  say "  · the repo whose pull requests get reviewed."
  # "blank to skip" was false whenever a repo was guessed: return takes the
  # DEFAULT, so blank watched the guess. Skipping needs a word of its own.
  if [ -n "$GUESS" ]; then
    say "       owner/name. return accepts $GUESS — type 'none' to watch nothing yet."
  else
    say "       owner/name — e.g. $LOGIN/my-app. return skips; add repos later with '$GOBLIN_SLUG ui'."
  fi
  if ! REPO="$(ask_valid '^$|^none$|^[A-Za-z0-9._-]{1,100}/[A-Za-z0-9._-]{1,100}$' \
        "a repo looks like owner/name — one slash, no url ('none' to skip)" \
        "  repo" "$GUESS")"; then
    warn "'$GUESS' is not an owner/name repo — skipping it"
    REPO=""
  fi
  [ "$REPO" = "none" ] && REPO=""
  if [ -n "$REPO" ]; then cfg_repo_add "$REPO"; ok "watching $REPO"
  else ok "no repo yet — add one with '$GOBLIN_SLUG ui'"; fi
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
    # agent_on retries through the asynchronous bootout (see lib/agent.sh); check
    # the real state afterwards rather than trusting either call.
    agent_stop; agent_on
    if agent_running; then ok "scheduled every ${INTERVAL}s ($AGENT_LABEL)"
    else
      err "the scheduler did not load — nothing will be reviewed until it does"
      say "        try:  $GOBLIN_SLUG agent start     then:  $GOBLIN_SLUG doctor"
    fi
  else
    err "generated plist is invalid: $AGENT_PLIST"
  fi
fi

# --- 7. menu bar app ------------------------------------------------------
# Built here rather than shipped: the app is ad-hoc signed on the machine it runs
# on, so there is nothing to notarise and no Gatekeeper prompt. app_build stages
# into $GOBLIN_HOME/build and swaps the finished bundle into place, so a running
# app is never modified underneath itself.
#
# It REPLACES the bundle rather than writing into it. The previous version of this
# step wrote a plist and a launcher script into whatever already existed at that
# path, which meant an older bundle survived in pieces: the 0.3.x app kept its
# compiled binary while losing the GBLCLIPath key that tells it where the CLI is,
# and every action in the panel then failed with "the Merge Goblin CLI path is
# missing from the app bundle". A bundle is replaced whole or not at all.
if [ "$WITH_MENU" = true ]; then
  say ""; say "menu bar app"
  # shellcheck source=lib/app.sh
  . "$APP/lib/app.sh"
  if app_install; then
    ok "app  → $APP_BUNDLE"
  else
    warn "the menu bar app did not build — the CLI and 'goblin ui' work without it"
  fi
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
