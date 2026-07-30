#!/usr/bin/env bash
# ui.sh — the control panel.
#
# A local web app rather than a native one: no Xcode, no Swift, no build step,
# nothing to notarise, and it works the moment someone clones the repo. It binds
# to 127.0.0.1 with a per-session token and shells every action back through the
# CLI, so there is exactly one implementation of the logic.
#
# The panel only runs while its process is alive. Opening it again reuses the
# running one instead of starting a second copy.

ui_python() {
  local p
  p="$(cfg_get '.ui.python' '')"
  [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  for p in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    command -v "$p" >/dev/null 2>&1 && { command -v "$p"; return 0; }
    [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  done
  return 1
}

# Is a panel already listening on the URL we last recorded?
ui_running_url() {
  [ -f "$UIURL" ] || return 1
  local url; url="$(cat "$UIURL" 2>/dev/null)"
  [ -n "$url" ] || return 1
  if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then
    printf '%s' "$url"; return 0
  fi
  rm -f "$UIURL" 2>/dev/null
  return 1
}

cmd_ui() {
  # 0 = let the OS pick a free port. An inherited GOBLIN_UI_PORT still wins unless
  # --port says otherwise, so scripts and tests can pin it.
  local open="${GOBLIN_UI_OPEN:-1}" port="${GOBLIN_UI_PORT:-0}" stop=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-open) open=0; shift ;;
      --port)    port="$2"; shift 2 ;;
      --stop)    stop=1; shift ;;
      --url)     ui_running_url && echo || echo "not running"; return 0 ;;
      *) shift ;;
    esac
  done
  cfg_ensure; cfg_backfill_defaults; goblin_ensure_dirs

  if [ "$stop" = 1 ]; then
    pkill -f "$SHARE_DIR/ui/server.py" 2>/dev/null && echo "control panel stopped" \
      || echo "control panel was not running"
    rm -f "$UIURL" 2>/dev/null
    return 0
  fi

  local existing
  if existing="$(ui_running_url)"; then
    echo "$existing"
    [ "$open" = 1 ] && open "$existing" 2>/dev/null
    return 0
  fi

  local py
  if ! py="$(ui_python)"; then
    cat >&2 <<EOF
The $GOBLIN_SHORT's control panel needs python3, which every Mac with the Xcode
command line tools already has. Install them with:

  xcode-select --install

…or point it at a python you already have:

  $GOBLIN_SLUG config set .ui.python /path/to/python3
EOF
    return 1
  fi

  # Refresh the state cache so the first paint isn't empty.
  status_set '{}' >/dev/null 2>&1

  GOBLIN_CLI="$GOBLIN_APP/bin/$GOBLIN_SLUG" \
  GOBLIN_HOME="$GOBLIN_HOME" \
  GOBLIN_UI_PORT="$port" \
  GOBLIN_UI_OPEN="$open" \
  GOBLIN_UI_URLFILE="$UIURL" \
    exec "$py" "$SHARE_DIR/ui/server.py"
}
