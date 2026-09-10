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

# Returns non-zero if the job is not loaded when this returns, so callers can say
# so instead of reporting a success that did not happen.
#
# `launchctl bootout` is ASYNCHRONOUS: it returns 0 while the job is still being
# torn down, and a `bootstrap` that lands in that window fails with
#
#     Bootstrap failed: 5: Input/output error
#
# install.sh does stop-then-start on every re-run — which is the documented upgrade
# path — so this raced every single time, and because the error was swallowed with
# `|| true` the installer went on to report the scheduler as installed while the
# machine had no scheduler at all. Reviews then silently stopped until someone
# noticed and ran `goblin agent start` by hand. Retry until the old job is really
# gone rather than guessing at a sleep.
agent_start() {
  local uid i=0; uid="$(id -u)"
  launchctl enable "gui/$uid/${AGENT_LABEL}" 2>/dev/null || true
  while [ "$i" -lt 25 ]; do
    launchctl bootstrap "gui/$uid" "$AGENT_PLIST" 2>/dev/null && return 0
    # Already loaded is a success, not a failure: bootstrap refuses a label that is
    # present, and a caller asking for "started" wants exactly that state.
    agent_running && return 0
    sleep 0.2; i=$((i + 1))
  done
  return 1
}

agent_stop() {
  launchctl bootout "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null \
    || launchctl bootout "gui/$(id -u)" "$AGENT_PLIST" 2>/dev/null || true
}

agent_off() { agent_stop; launchctl disable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true; }
agent_on()  { launchctl enable "gui/$(id -u)/${AGENT_LABEL}" 2>/dev/null || true; agent_start; }
# No sleep here any more: agent_start waits for the bootout to finish and retries,
# which is both more reliable than one second and faster when the job is already gone.
agent_reload() { agent_stop; agent_start; }

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
#
# Three outcomes, not two. GitHub being briefly unreachable is not an answer about
# who the token belongs to, and reporting it as one is a lie that costs an
# afternoon: a blip in `gh api user` used to surface as
#   token identity mismatch: token is '', expected 'you' - abort
# plus a "github token is not you" push, which accuses the one thing that is
# definitely fine and sends you off rotating a perfectly good credential.
#   0 - confirmed: the token is $want
#   1 - confirmed otherwise: GitHub answered, and named somebody else. Abort.
#   2 - unknown: could not ask. Not a mismatch; the caller says so honestly.
# GH_IDENTITY_ACTUAL carries whatever GitHub said, so the caller reports the login
# we actually saw rather than re-asking (a second call that can fail the same way,
# which is why the old message printed an empty string).
gh_assert_identity() {
  local want="${1:-$GOBLIN_LOGIN}" i=0
  GH_IDENTITY_ACTUAL=""
  [ -z "$want" ] && return 0
  while [ "$i" -lt 3 ]; do
    GH_IDENTITY_ACTUAL="$(gh api user --jq .login 2>/dev/null)"
    if [ -n "$GH_IDENTITY_ACTUAL" ]; then
      # Logins are case-insensitive on GitHub, so `you` and `You` are one account.
      # Only a config typo ever makes the case differ, and aborting over that is a
      # mismatch we invented rather than one GitHub reported.
      [ "$(lc "$GH_IDENTITY_ACTUAL")" = "$(lc "$want")" ] && return 0
      return 1
    fi
    i=$((i + 1)); [ "$i" -lt 3 ] && sleep 1
  done
  return 2
}

# Does this account actually have the repo? Same three-way split as the identity
# check, for the same reason: "not visible to this account" sends you to check org
# access and SSO grants, so it must only be said when GitHub really said no.
#   0 - visible   1 - GitHub answered no   2 - could not ask
# The discriminator is a second call the repo answer does not depend on: if the API
# is reachable at all, then a repo call that still fails is a real no. `rate_limit`
# is the probe because it does not itself consume quota.
gh_repo_visible() {
  local slug="$1" i=0
  while [ "$i" -lt 3 ]; do
    gh api "repos/$slug" --jq .full_name >/dev/null 2>&1 && return 0
    i=$((i + 1)); [ "$i" -lt 3 ] && sleep 1
  done
  gh api rate_limit >/dev/null 2>&1 && return 1
  return 2
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
