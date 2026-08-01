#!/usr/bin/env bash
# agent.sh — launchd control + gh account helpers.

agent_running() { launchctl print "gui/$(id -u)/${AGENT_LABEL}" >/dev/null 2>&1; }

# Installed is not the same as running, and the menu bar icon depends on the
# difference: "a schedule exists but did not load" is a fault worth a red glyph,
# whereas "no schedule was ever installed" is just a machine that hasn't been set
# up, which doctor already reports. Without this the icon cried wolf on every
# --no-agent install.
agent_installed() { [ -f "$AGENT_PLIST" ]; }

# A persistent `disable` override survives reboots/logins — unlike a plain
# bootout, which the plist re-loads at next login. This is what makes "off"
# actually mean off.
agent_disabled() {
  launchctl print-disabled "gui/$(id -u)" 2>/dev/null \
    | grep -qE "\"${AGENT_LABEL}\"[[:space:]]*=>[[:space:]]*disabled"
}

agent_start() {
  launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
}

agent_stop() {
  launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null \
    || launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
}

agent_off() { agent_stop; launchctl disable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true; }
agent_on()  { launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true; agent_start; }
agent_reload() { agent_stop; sleep 1; agent_start; }

# --- github identity ------------------------------------------------------

# The account gh would use by default. Read offline from hosts.yml — no network,
# safe to call on every menu render.
gh_active_account() {
  awk '/^github\.com:/{f=1; next} /^[^[:space:]]/{f=0} f && $1=="user:"{print $2; exit}' \
    "$HOME/.config/gh/hosts.yml" 2>/dev/null
}

# Pin GH_TOKEN to OUR login rather than whatever account happens to be active.
# A second gh account becoming active silently makes `@me` resolve to the wrong
# user and every run finds nothing — this happened three times before the pin.
gh_pin_token() {
  local want="${1:-}"
  [ -z "$want" ] && want="$(goblin_login)"
  local tok
  tok="$(gh auth token --user "$want" 2>/dev/null)"
  [ -z "$tok" ] && tok="$(gh auth token 2>/dev/null)"
  [ -z "$tok" ] && return 1
  export GH_TOKEN="$tok"
  GOBLIN_LOGIN="$want"
  return 0
}

# Verify the pinned token really is who we think, so we never review as someone else.
gh_assert_identity() {
  local want="${1:-$GOBLIN_LOGIN}" actual
  actual="$(gh api user --jq .login 2>/dev/null)"
  [ -z "$want" ] && return 0
  [ "$actual" = "$want" ]
}

# Pin the token and confirm the identity, without any of the engine's git
# plumbing. Read-only commands — `inbox`, the panel's queries — need a correctly
# scoped token but have no business exporting a GIT_CONFIG URL rewrite into their
# environment, and they must not have to source the whole engine to get one.
engine_auth_lite() {
  command -v gh >/dev/null 2>&1 || return 1
  GOBLIN_LOGIN="$(goblin_login)"
  gh_pin_token "$GOBLIN_LOGIN" || return 1
  gh_assert_identity "$GOBLIN_LOGIN" || return 1
  return 0
}
