#!/usr/bin/env bash
# doctor.sh — the difference between a tool a teammate keeps and one they delete.
#
# Every silent failure this project has hit is a check here: the active gh
# account flipping to one without repo access, a scratch clone left dirty so
# every checkout aborted, a provider binary moving, python missing for the panel.
# Each failure prints the exact command that fixes it.

DOC_PASS=0; DOC_WARN=0; DOC_FAIL=0; DOC_JSON="[]"; DOC_FIX=false; DOC_AS_JSON=false

_doc() {  # _doc <ok|warn|fail> <check> <detail> [fix]
  local st="$1" name="$2" detail="$3" fix="${4:-}"
  case "$st" in
    ok)   DOC_PASS=$((DOC_PASS+1)) ;;
    warn) DOC_WARN=$((DOC_WARN+1)) ;;
    fail) DOC_FAIL=$((DOC_FAIL+1)) ;;
  esac
  DOC_JSON="$(printf '%s' "$DOC_JSON" | jq -c --arg s "$st" --arg n "$name" --arg d "$detail" --arg f "$fix" \
    '. + [{status:$s, check:$n, detail:$d, fix:$f}]')"
  [ "$DOC_AS_JSON" = true ] && return 0
  local icon
  case "$st" in ok) icon="✓" ;; warn) icon="!" ;; fail) icon="✗" ;; esac
  printf '  %s %-22s %s\n' "$icon" "$name" "$detail"
  [ -n "$fix" ] && [ "$st" != "ok" ] && printf '      → %s\n' "$fix"
}

cmd_doctor() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --fix)  DOC_FIX=true; shift ;;
      --json) DOC_AS_JSON=true; shift ;;
      *) shift ;;
    esac
  done
  cfg_ensure; cfg_backfill_defaults
  . "$LIB_DIR/providers.sh"; . "$LIB_DIR/github.sh"

  [ "$DOC_AS_JSON" = false ] && printf '\n%s %s v%s — checkup\n\n' "$GOBLIN_EMOJI" "$GOBLIN_NAME" "$GOBLIN_VERSION"

  doctor_deps
  doctor_identity
  doctor_providers
  doctor_repos
  doctor_agent
  doctor_menu
  doctor_state

  if [ "$DOC_AS_JSON" = true ]; then
    jq -nc --argjson checks "$DOC_JSON" --argjson p "$DOC_PASS" --argjson w "$DOC_WARN" --argjson f "$DOC_FAIL" \
      '{pass:$p, warn:$w, fail:$f, checks:$checks}'
  else
    printf '\n  %s passed · %s warnings · %s failures\n\n' "$DOC_PASS" "$DOC_WARN" "$DOC_FAIL"
  fi
  # Record it so the control panel can show a health badge without re-running this.
  status_set "$(jq -nc --argjson f "$DOC_FAIL" --argjson w "$DOC_WARN" --argjson at "$(now_epoch)" \
    '{doctor:{fail:$f, warn:$w, at:$at}}')"

  [ "$DOC_FAIL" -gt 0 ] && return 1
  [ "$DOC_WARN" -gt 0 ] && return 0
  return 0
}

doctor_deps() {
  local c
  for c in gh jq git; do
    if command -v "$c" >/dev/null 2>&1; then _doc ok "$c" "$(command -v "$c")"
    else _doc fail "$c" "not installed" "brew install $c"; fi
  done
  if [ "$(printf '%s' "${BASH_VERSION:-0}" | cut -d. -f1)" -lt 3 ] 2>/dev/null; then
    _doc warn bash "unexpectedly old: ${BASH_VERSION:-?}" ""
  fi
}

doctor_identity() {
  local want active
  want="$(cfg_get '.identity.githubLogin' '')"
  active="$(gh_active_account)"

  if ! gh auth status >/dev/null 2>&1; then
    _doc fail "github auth" "not logged in" "gh auth login"; return
  fi
  if [ -z "$want" ]; then
    if [ -n "$active" ]; then
      _doc warn "github identity" "not pinned (using active account '$active')" \
        "$GOBLIN_SLUG config set .identity.githubLogin $active"
      want="$active"
    else
      _doc fail "github identity" "no account" "gh auth login"; return
    fi
  fi

  # The token, not the active account, is what actually matters — the Goblin pins it.
  local tok whoami
  tok="$(gh auth token --user "$want" 2>/dev/null)"
  if [ -z "$tok" ]; then
    _doc fail "github token" "no stored token for '$want'" "gh auth login --user $want"
    return
  fi
  whoami="$(GH_TOKEN="$tok" gh api user --jq .login 2>/dev/null)"
  if [ "$whoami" = "$want" ]; then
    if [ "$active" != "$want" ]; then
      # Not fatal: the Goblin pins the token per call, so this only affects YOUR shell.
      _doc warn "github account" "the Goblin uses '$want'; your shell's active account is '$active'" \
        "$GOBLIN_SLUG fix-account   (only needed for your own gh commands)"
    else
      _doc ok "github account" "$want"
    fi
  else
    _doc fail "github token" "token for '$want' resolves to '$whoami'" "gh auth refresh --user $want"
  fi
  GOBLIN_LOGIN="$want"; export GH_TOKEN="$tok"
}

doctor_providers() {
  local probes cur ready
  cur="$(cfg_get '.provider' claude)"
  probes="$(providers_probe_all)"
  ready="$(printf '%s' "$probes" | jq -r '[.[] | select(.available and .authed)] | length')"

  if [ "${ready:-0}" -eq 0 ]; then
    _doc fail "ai provider" "none installed and authenticated" \
      "install one: claude (claude.ai/code) · codex (npm i -g @openai/codex) · cursor (curl https://cursor.com/install -fsS | bash)"
    return
  fi

  local p; p="$(printf '%s' "$probes" | jq -c --arg c "$cur" '.[] | select(.name == $c)')"
  if [ -z "$p" ] || [ "$(printf '%s' "$p" | jq -r '.available')" != "true" ]; then
    _doc fail "provider ($cur)" "selected provider is not installed" "$GOBLIN_SLUG provider use <one that is ready>"
  elif [ "$(printf '%s' "$p" | jq -r '.authed')" != "true" ]; then
    _doc fail "provider ($cur)" "installed but not signed in" "$(printf '%s' "$p" | jq -r '.note')"
  else
    _doc ok "provider ($cur)" "$(printf '%s' "$p" | jq -r '"\(.authMode // "ok") · cost \(if .costKnown then "tracked" else "not reported" end)"')"
  fi
  _doc ok "providers ready" "$(printf '%s' "$probes" | jq -r '[.[] | select(.available and .authed) | .name] | join(", ")')"
}

doctor_repos() {
  local repos; repos="$(cfg_repos_enabled)"
  if [ -z "$repos" ]; then
    _doc warn repos "none configured" "$GOBLIN_SLUG repos add owner/name"; return
  fi
  local slug dir
  for slug in $repos; do
    if gh api "repos/$slug" --jq .full_name >/dev/null 2>&1; then
      _doc ok "repo $slug" "reachable"
    else
      _doc fail "repo $slug" "not visible to this account" "check access, or: $GOBLIN_SLUG repos rm $slug"
      continue
    fi
    dir="$(goblin_repo_dir "$slug")"
    if [ -d "$dir/.git" ] || [ -L "$dir" ]; then
      local dirty; dirty="$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      if [ "${dirty:-0}" -gt 0 ]; then
        if [ "$DOC_FIX" = true ]; then
          git -C "$dir" reset --hard --quiet >/dev/null 2>&1; git -C "$dir" clean -ffd >/dev/null 2>&1
          _doc ok "clone $slug" "was dirty ($dirty files) — cleaned"
        else
          # This exact state silently blocked every checkout once.
          _doc warn "clone $slug" "$dirty uncommitted file(s) — will block checkouts" "$GOBLIN_SLUG doctor --fix"
        fi
      else
        _doc ok "clone $slug" "clean"
      fi
    else
      _doc ok "clone $slug" "not cloned yet (will clone on first review)"
    fi
  done
}

doctor_agent() {
  if [ ! -f "$AGENT_PLIST" ]; then
    _doc warn "scheduler" "not installed" "./install.sh"; return
  fi
  if agent_disabled; then
    _doc warn "scheduler" "turned off (persistent)" "$GOBLIN_SLUG on"
  elif agent_running; then
    _doc ok "scheduler" "loaded · every $(cfg_get '.intervalSeconds' 300)s · $AGENT_LABEL"
  else
    if [ "$DOC_FIX" = true ]; then agent_start; _doc ok "scheduler" "was not loaded — started"
    else _doc warn "scheduler" "not loaded" "$GOBLIN_SLUG agent start"; fi
  fi
  if [ -d "$LOCKDIR" ]; then
    if [ -n "$(find "$LOCKDIR" -maxdepth 0 -mmin +180 2>/dev/null)" ]; then
      if [ "$DOC_FIX" = true ]; then rm -rf "$LOCKDIR"; _doc ok "lock" "stale lock removed"
      else _doc warn "lock" "stale lock held" "$GOBLIN_SLUG doctor --fix"; fi
    else
      _doc ok "lock" "a run is in progress"
    fi
  fi
}

doctor_menu() {
  . "$LIB_DIR/ui.sh"
  local py
  if py="$(ui_python)"; then
    _doc ok "control panel" "ready — run: $GOBLIN_SLUG ui   ($py)"
  else
    _doc warn "control panel" "needs python3" "xcode-select --install"
  fi
}

doctor_state() {
  local free
  free="$(df -g "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "$free" ] && [ "$free" -lt 5 ] 2>/dev/null; then
    _doc warn "disk" "${free}GB free — clones need room" "free some space"
  else
    _doc ok "disk" "${free:-?}GB free"
  fi
  local ver; ver="$(cfg_get '.schemaVersion' 0)"
  if [ "$ver" != "$GOBLIN_CONFIG_SCHEMA_VERSION" ]; then
    _doc warn config "schema v$ver, expected v$GOBLIN_CONFIG_SCHEMA_VERSION" "$GOBLIN_SLUG doctor --fix"
  else
    _doc ok config "v$ver · $CONFIG"
  fi
  local legacy="$HOME/conductor/prauto.config.json"
  if [ -f "$legacy" ] && [ ! -f "$GOBLIN_HOME/.migrated" ]; then
    _doc warn "legacy state" "found the old prauto setup" "$GOBLIN_SLUG migrate"
  fi
  local last; last="$(cat "$STATUS" 2>/dev/null | jq -r '.lastRunFinished // 0' 2>/dev/null)"
  if [ "${last:-0}" -gt 0 ] 2>/dev/null; then
    _doc ok "last run" "$(date -r "$last" '+%Y-%m-%d %H:%M')"
  else
    _doc ok "last run" "never"
  fi
}
