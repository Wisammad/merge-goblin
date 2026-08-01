#!/usr/bin/env bash
# app.sh — the menu bar app: build, install, remove, login item.
#
# The app is Swift, so it needs a compile step. That step lives here rather than
# in install.sh for three reasons: shellcheck covers lib/, `goblin app rebuild`
# exists for when someone edits share/ui/panel.css and wants to see it, and
# install.sh stays a script about installing rather than about Swift.
#
# Nothing here requires Xcode. AppKit and WebKit are present in the Command Line
# Tools alone, so there is no xcodebuild, no .xcodeproj, no asset catalog (actool
# is Xcode-only) and no nib (ibtool is Xcode-only). If swiftc is missing entirely
# the build prints the one-line fix and SKIPS, because a missing menu bar app must
# never be the reason an install fails — the CLI works without it.
#
# Written for bash 3.2, which is what /bin/bash on macOS actually is.

GOBLIN_APP_SRC="${GOBLIN_APP_SRC:-$GOBLIN_APP/app}"
GOBLIN_APP_TEST_SRC="${GOBLIN_APP_TEST_SRC:-$GOBLIN_APP/app-tests}"
APP_EXEC_NAME="GoblinBar"
APP_BUNDLE="${GOBLIN_APP_BUNDLE:-$HOME/Applications/$GOBLIN_SHORT.app}"

# LaunchServices caches an app's Info.plist by path. The bundle at this path is
# changing its LSUIElement status (the old one was a script bundle without it), so
# without a forced re-register macOS keeps answering from the stale copy and the
# app gets a phantom Dock icon it can never lose.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Same sanitiser as goblin_agent_label() in paths.sh, so the two labels agree on
# what a username is. The bundle identifier and the login-item label are the same
# string on purpose: one name to grep for in `launchctl list` and Activity Monitor.
app_bundle_id() {
  local u
  u="$(id -un 2>/dev/null | tr -cd '[:alnum:]._-')"
  printf 'com.%s.%s.bar' "${u:-user}" "$GOBLIN_SLUG"
}

app_bar_plist() { printf '%s/Library/LaunchAgents/%s.plist' "$HOME" "$(app_bundle_id)"; }
app_exec_path() { printf '%s/Contents/MacOS/%s' "$APP_BUNDLE" "$APP_EXEC_NAME"; }

# --- toolchain ------------------------------------------------------------

# Prefer xcrun's swiftc so the right SDK is selected on a machine that has both
# the Command Line Tools and Xcode.
app_swiftc() {
  local p
  if command -v xcrun >/dev/null 2>&1; then
    p="$(xcrun --sdk macosx --find swiftc 2>/dev/null)"
    [ -n "$p" ] && [ -x "$p" ] && { printf '%s' "$p"; return 0; }
  fi
  p="$(command -v swiftc 2>/dev/null)"
  [ -n "$p" ] && { printf '%s' "$p"; return 0; }
  return 1
}

app_swiftc_missing_hint() {
  cat >&2 <<EOF
  ! the menu bar app needs swiftc, which comes with the Xcode command line tools:

        xcode-select --install

    skipping the app for now — the CLI works without it, and
    '$GOBLIN_SLUG app rebuild' will pick it up once the tools are installed.
EOF
}

# --- build ----------------------------------------------------------------

app_build() {
  local swiftc sdk target macos res f plist stage
  local -a flags

  if [ ! -d "$GOBLIN_APP_SRC" ]; then
    echo "  ! swift sources not found at $GOBLIN_APP_SRC — skipping the menu bar app" >&2
    return 0
  fi

  if ! swiftc="$(app_swiftc)"; then
    app_swiftc_missing_hint
    return 0
  fi

  # Before the compile, not after: a silent ten-second pause in an installer
  # reads as a hang, and people kill it.
  echo "  compiling the menu bar app (about 10 seconds)…"

  # BUILD INTO A STAGING BUNDLE, NEVER THE LIVE ONE.
  #
  # This used to killall the app and then compile and copy straight into
  # ~/Applications/…app over ten-plus seconds. The bar's LaunchAgent has
  # KeepAlive, so it restarted the app a second or two into that window — and
  # macOS will not let an unprivileged process modify a signed bundle whose app is
  # running (the bundle carries com.apple.provenance, so App Management applies).
  # The copy into Contents/Resources/ui failed with EPERM, app_build returned early,
  # and because the Info.plist is written after the resources the result was a
  # bundle with an executable and NO Info.plist. The app still launched, because the
  # LaunchAgent execs the binary directly and does not need one, but every
  # Info.plist lookup then returned nil — surfacing as "the Merge Goblin CLI path is
  # missing from the app bundle" in the panel. Killing the app first is not a fix;
  # the agent races the build every time.
  #
  # Staging means the live bundle is untouched until a complete, signed bundle
  # exists, and the swap is a delete-and-move rather than an in-place edit.
  stage="$GOBLIN_HOME/build/$(basename "$APP_BUNDLE")"
  rm -rf "$stage"
  macos="$stage/Contents/MacOS"
  res="$stage/Contents/Resources"
  mkdir -p "$macos" "$res/ui" || { echo "  ✗ cannot create $stage" >&2; return 1; }

  target="$(uname -m)-apple-macos13.0"
  sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
  flags=(-O -whole-module-optimization -target "$target" -framework AppKit -framework WebKit)
  [ -n "$sdk" ] && flags=("${flags[@]}" -sdk "$sdk")

  if ! "$swiftc" "${flags[@]}" -o "$macos/$APP_EXEC_NAME" "$GOBLIN_APP_SRC"/*.swift; then
    echo "  ✗ the menu bar app did not compile" >&2
    return 1
  fi

  # The panel is served to a WKWebView out of Contents/Resources/ui, by exact
  # filename (see app/ResourceScheme.swift). Adding a file to the panel means
  # adding it in both places.
  for f in panel.html panel.css panel.js wizard.js goblin.svg goblin-bar.pdf; do
    if [ -f "$SHARE_DIR/ui/$f" ]; then
      cp "$SHARE_DIR/ui/$f" "$res/ui/$f" || return 1
    else
      echo "  ! share/ui/$f is missing; the panel will be incomplete" >&2
    fi
  done
  [ -f "$SHARE_DIR/ui/goblin.icns" ] && cp "$SHARE_DIR/ui/goblin.icns" "$res/goblin.icns"

  plist="$stage/Contents/Info.plist"
  sed -e "s|__NAME__|$GOBLIN_NAME|g" \
      -e "s|__SHORT__|$GOBLIN_SHORT|g" \
      -e "s|__VERSION__|$GOBLIN_VERSION|g" \
      -e "s|__BUNDLE_ID__|$(app_bundle_id)|g" \
      -e "s|__EXEC__|$APP_EXEC_NAME|g" \
      -e "s|__CLI__|$GOBLIN_APP/bin/$GOBLIN_SLUG|g" \
      -e "s|__GOBLIN_HOME__|$GOBLIN_HOME|g" \
      "$TEMPLATE_DIR/app-info.plist.tmpl" > "$plist"
  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    echo "  ✗ generated Info.plist is invalid: $plist" >&2
    return 1
  fi

  # AFTER every file is in place: a signature covers the bundle's contents, so
  # signing first and then copying resources produces a bundle that fails its own
  # validation. Ad-hoc (--sign -) is enough for a locally built app.
  if ! codesign --force --sign - --identifier "$(app_bundle_id)" "$stage" >/dev/null 2>&1; then
    echo "  ! ad-hoc signing failed; macOS may refuse to launch the app" >&2
  fi

  # Refuse to swap in anything incomplete. The whole point of staging is that a
  # failed build leaves the working app alone, so verify the two things whose
  # absence produced the broken half-bundle before touching what is installed.
  if [ ! -x "$macos/$APP_EXEC_NAME" ]; then
    echo "  ✗ built bundle has no executable — keeping the installed app" >&2
    return 1
  fi
  if ! plutil -extract GBLCLIPath raw "$plist" >/dev/null 2>&1; then
    echo "  ✗ built bundle has no CLI path in Info.plist — keeping the installed app" >&2
    return 1
  fi

  app_swap_bundle "$stage" || return 1
  rm -rf "$stage"

  echo "  ✓ menu bar app → $APP_BUNDLE"
  return 0
}

# app_swap_bundle <staged.app> — replace the installed bundle with a built one.
#
# The LaunchAgent is booted out for the duration. Without that its KeepAlive
# relaunches the app from a path that is being deleted, which is how the bundle got
# corrupted in the first place; it also means the running app keeps the OLD code
# until something restarts it, so users saw fixes "not apply" after a rebuild.
app_swap_bundle() {
  local stage="$1" label uid plist_agent was_loaded=false
  label="$(app_bundle_id)"; uid="$(id -u)"
  plist_agent="$(app_bar_plist)"

  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    was_loaded=true
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
  fi
  killall "$APP_EXEC_NAME" 2>/dev/null || true

  # Give the process time to actually exit. Deleting a bundle out from under a
  # running app is what EPERMs.
  local i=0
  while pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1 && [ "$i" -lt 25 ]; do
    sleep 0.2; i=$((i + 1))
  done
  pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1 && killall -9 "$APP_EXEC_NAME" 2>/dev/null || true

  [ -x "$LSREGISTER" ] && [ -d "$APP_BUNDLE" ] && "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1

  mkdir -p "$(dirname "$APP_BUNDLE")"
  rm -rf "$APP_BUNDLE"
  # ditto rather than mv: it copies across filesystems and preserves the bundle's
  # metadata and the signature we just applied.
  if ! ditto "$stage" "$APP_BUNDLE" 2>/dev/null; then
    echo "  ✗ could not install the bundle to $APP_BUNDLE" >&2
    [ "$was_loaded" = true ] && launchctl bootstrap "gui/$uid" "$plist_agent" 2>/dev/null || true
    return 1
  fi

  [ -x "$LSREGISTER" ] && "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null 2>&1

  # Bring the bar back only if it was running before, so a rebuild does not launch
  # an app the user had deliberately quit.
  if [ "$was_loaded" = true ] && [ -f "$plist_agent" ]; then
    launchctl bootstrap "gui/$uid" "$plist_agent" 2>/dev/null || true
  fi
  return 0
}

# --- tests ----------------------------------------------------------------

# The allowlist's test suite. A plain executable, not XCTest, because XCTest needs
# xcodebuild or a Swift package and this project deliberately needs neither.
app_test() {
  local swiftc sdk out
  local -a flags

  [ -d "$GOBLIN_APP_TEST_SRC" ] || { echo "no app tests at $GOBLIN_APP_TEST_SRC" >&2; return 0; }
  if ! swiftc="$(app_swiftc)"; then app_swiftc_missing_hint; return 0; fi

  out="${RUNTMP:-/tmp}/goblin-app-tests"
  mkdir -p "$(dirname "$out")" 2>/dev/null || true
  sdk="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)"
  flags=(-target "$(uname -m)-apple-macos13.0")
  [ -n "$sdk" ] && flags=("${flags[@]}" -sdk "$sdk")

  # Command.swift only: it imports Foundation and nothing else, precisely so the
  # allowlist can be tested with no window server and no app bundle.
  "$swiftc" "${flags[@]}" -o "$out" \
    "$GOBLIN_APP_SRC/Command.swift" "$GOBLIN_APP_TEST_SRC/main.swift" || return 1
  "$out"
}

# --- install / remove -----------------------------------------------------

app_install() {
  app_build || return 1
  echo "        open it from Spotlight, or run: open -a \"$APP_BUNDLE\""
  echo "        turn on 'Start at login' in its menu to have it there every morning"
}

app_remove() {
  local plist label
  plist="$(app_bar_plist)"
  label="$(app_bundle_id)"

  launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
  rm -f "$plist"
  killall "$APP_EXEC_NAME" 2>/dev/null || true
  if [ -d "$APP_BUNDLE" ]; then
    [ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$APP_BUNDLE" >/dev/null 2>&1
    rm -rf "$APP_BUNDLE"
    echo "removed $APP_BUNDLE"
  else
    echo "the menu bar app was not installed"
  fi
}

# --- login item -----------------------------------------------------------

app_login_item_on() {
  local plist label exec_path uid
  exec_path="$(app_exec_path)"
  if [ ! -x "$exec_path" ]; then
    echo "the menu bar app is not built — run: $GOBLIN_SLUG app rebuild" >&2
    return 1
  fi

  plist="$(app_bar_plist)"
  label="$(app_bundle_id)"
  uid="$(id -u)"
  mkdir -p "$HOME/Library/LaunchAgents" || return 1

  sed -e "s|__LABEL__|$label|g" -e "s|__EXEC__|$exec_path|g" \
      "$TEMPLATE_DIR/bar-agent.plist.tmpl" > "$plist"
  if ! plutil -lint "$plist" >/dev/null 2>&1; then
    rm -f "$plist"
    echo "generated login item plist is invalid" >&2
    return 1
  fi

  # A persistent `disable` override from an earlier 'off' would silently win over
  # bootstrap, so clear it first.
  launchctl enable "gui/$uid/$label" 2>/dev/null || true

  if launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
    # Already loaded. Only replace it when the app is NOT up: bootout would quit
    # a running menu bar item under the user's cursor, and the user just asked for
    # more of it, not less.
    if ! pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1; then
      launchctl bootout "gui/$uid/$label" 2>/dev/null || true
      launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
    fi
  else
    launchctl bootstrap "gui/$uid" "$plist" 2>/dev/null || true
  fi

  echo "the $GOBLIN_SHORT will open at login"
}

app_login_item_off() {
  local plist
  plist="$(app_bar_plist)"

  # Only the plist is removed; the loaded job is left alone deliberately. Booting
  # it out would terminate the app that is running right now — the user unticked
  # "Start at login", which is about tomorrow, not about closing the thing they
  # are looking at. With the plist gone, launchd does not load it next login.
  rm -f "$plist"
  echo "the $GOBLIN_SHORT will no longer open at login"
}

app_login_item_status() {
  if [ -f "$(app_bar_plist)" ]; then echo "on"; else echo "off"; fi
}

# --- dispatcher -----------------------------------------------------------

# `goblin ui` / `goblin open` — muscle memory, and what install.sh advertises. The
# panel is no longer a served web page, so this just brings the app forward.
cmd_ui() {
  case "${1:-}" in
    --stop)
      # Replaces `pkill -f server.py`, which matched on an absolute path and so
      # silently failed to stop a panel started from a different checkout.
      osascript - "$(app_bundle_id)" >/dev/null 2>&1 <<'APPLESCRIPT' || killall "$APP_EXEC_NAME" 2>/dev/null || true
on run argv
	tell application id (item 1 of argv) to quit
end run
APPLESCRIPT
      echo "closed"; return 0 ;;
    --url|--port|--no-open)
      echo "the panel is part of the app now — there is no URL or port" >&2
      echo "open it with: $GOBLIN_SLUG ui" >&2
      return 2 ;;
  esac

  if [ ! -x "$(app_exec_path)" ]; then
    echo "the $GOBLIN_SHORT app is not built yet — run: $GOBLIN_SLUG app rebuild" >&2
    return 1
  fi
  open "$APP_BUNDLE" 2>/dev/null || {
    echo "could not open $APP_BUNDLE" >&2; return 1; }
}

# Open straight onto the wizard. Used by `goblin setup` and printed by install.sh
# when setup is still incomplete.
cmd_app_open_wizard() {
  cfg_ensure; cfg_backfill_defaults
  if [ ! -x "$(app_exec_path)" ]; then
    # No GUI available: say exactly what to do rather than dead-ending.
    echo "the app is not built (run: $GOBLIN_SLUG app rebuild)."
    echo "you can also set up from the terminal:"
    echo "  $GOBLIN_SLUG accounts                      # pick one"
    echo "  $GOBLIN_SLUG panel set identity <login>"
    echo "  $GOBLIN_SLUG provider list                 # pick one that says ready"
    echo "  $GOBLIN_SLUG provider use <id>"
    echo "  $GOBLIN_SLUG repos search -q <name>"
    echo "  $GOBLIN_SLUG repos add owner/name"
    echo "  $GOBLIN_SLUG panel set setup-complete 1"
    return 1
  fi
  cmd_ui
}

cmd_app() {
  local sub="${1:-status}"
  shift 2>/dev/null || true

  case "$sub" in
    build|rebuild) app_build ;;
    open-wizard)   cmd_app_open_wizard ;;
    install)       app_install ;;
    remove|uninstall) app_remove ;;
    test)          app_test ;;
    path)          echo "$APP_BUNDLE" ;;
    label)         app_bundle_id; echo ;;
    login-item)
      case "${1:-status}" in
        on)     app_login_item_on ;;
        off)    app_login_item_off ;;
        status) app_login_item_status ;;
        *) echo "usage: $GOBLIN_SLUG app login-item [on|off|status]" >&2; return 2 ;;
      esac ;;
    status)
      echo "bundle:     $APP_BUNDLE"
      echo "installed:  $([ -x "$(app_exec_path)" ] && echo yes || echo no)"
      echo "running:    $(pgrep -x "$APP_EXEC_NAME" >/dev/null 2>&1 && echo yes || echo no)"
      echo "identifier: $(app_bundle_id)"
      echo "login item: $(app_login_item_status)" ;;
    *)
      echo "usage: $GOBLIN_SLUG app [status|rebuild|install|remove|test|path|login-item on|off]" >&2
      return 2 ;;
  esac
}
