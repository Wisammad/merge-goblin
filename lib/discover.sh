#!/usr/bin/env bash
# discover.sh — the questions the first-run wizard asks GitHub and the machine.
#
# Everything the app needs goes through a goblin subcommand rather than the app
# shelling out to `gh` itself. Four reasons, in order of weight:
#
#   1. The identity logic is subtle and already written here. goblin_login prefers
#      the configured login and only falls back to the active account, and
#      gh_pin_token exists *because* a second gh account becoming active silently
#      made every run resolve to the wrong user — three separate times. Reproducing
#      that in Swift guarantees the two drift.
#   2. Offline testability: the suite already puts tests/fixtures/bin on PATH, so a
#      gh stub makes this whole path assertable with no network and no GUI. There
#      is no equivalent rig for Swift.
#   3. Debuggability: `goblin repos search --json | jq` is something a teammate can
#      run. NSTask output is not.
#   4. A gh spawn from a GUI app inherits a minimal PATH; core.sh fixes that once,
#      here, for everything.

# --- github accounts ------------------------------------------------------
#
# Read from hosts.yml rather than `gh auth status`, which is prose-only in gh 2.86
# and would have to be scraped. Offline means the wizard dropdown paints instantly.
gh_accounts() {
  awk '
    /^[^[:space:]#].*:[[:space:]]*$/ { host = $1; sub(/:$/, "", host); inusers = 0; next }
    /^[[:space:]]+users:[[:space:]]*$/ { inusers = 1; next }
    # a users: child is indented deeper than "users:" itself
    inusers && /^[[:space:]]{8}[^[:space:]]+:[[:space:]]*$/ {
      l = $1; sub(/:$/, "", l); print l; next
    }
    /^[[:space:]]{4}[^[:space:]]+:/ { if ($1 != "users:") inusers = 0 }
  ' "$HOME/.config/gh/hosts.yml" 2>/dev/null | sort -u
}

# goblin accounts --json -> [{login, active, hasToken, configured}]
cmd_accounts() {
  local as_json=false verify=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)   as_json=true; shift ;;
      --verify) verify=true; shift ;;
      *) shift ;;
    esac
  done

  local active configured out="[]" l tok ver
  active="$(gh_active_account)"
  configured="$(cfg_get '.identity.githubLogin' '')"

  # `gh auth status` is a union fallback only: if hosts.yml is somewhere unusual
  # we would otherwise show an empty list and the wizard would look broken.
  local logins; logins="$(gh_accounts)"
  if [ -z "$logins" ]; then
    logins="$(gh auth status 2>&1 | sed -n 's/.*account \([A-Za-z0-9-]*\).*/\1/p' | sort -u)"
  fi

  while IFS= read -r l; do
    [ -z "$l" ] && continue
    tok=false
    [ -n "$(gh auth token --user "$l" 2>/dev/null)" ] && tok=true
    ver=null
    if [ "$verify" = true ] && [ "$tok" = true ]; then
      # Costs a request per account, so only on demand: a token can exist and
      # still resolve to somebody else after a re-auth.
      if [ "$(GH_TOKEN="$(gh auth token --user "$l" 2>/dev/null)" gh api user --jq .login 2>/dev/null)" = "$l" ]; then
        ver=true; else ver=false
      fi
    fi
    out="$(printf '%s' "$out" | jq -c --arg l "$l" --arg a "$active" --arg c "$configured" \
      --argjson t "$tok" --argjson v "$ver" \
      '. + [{login:$l, active:($l==$a), configured:($l==$c), hasToken:$t, verified:$v}]')"
  done <<EOF
$logins
EOF

  if [ "$as_json" = true ]; then printf '%s\n' "$out"; return 0; fi
  printf '%s' "$out" | jq -r '.[] |
    (if .configured then "* " else "  " end) + .login
    + (if .active then "  (gh active)" else "" end)
    + (if .hasToken then "" else "  — no stored token, run: gh auth login" end)'
}

# --- accessible repos -----------------------------------------------------
#
# Cached and filtered LOCALLY, so typing in the wizard costs nothing. Same shape
# as the teams cache: fetch once, reuse for an hour.
REPOS_CACHE_FILE=""
repos_cache_path() { printf '%s/repos-cache.json' "$GOBLIN_HOME"; }

repos_cache_fetch() {
  local cache; cache="$(repos_cache_path)"
  local all="[]" org orgs

  # The user's own repos, then every org they belong to. `gh repo list` is scoped
  # to what the token can actually see, which is exactly the right scope — do NOT
  # fall back to `gh search repos`, which returns things you cannot review.
  all="$(gh repo list --limit 200 --json nameWithOwner,description,isPrivate,isArchived,pushedAt,viewerPermission 2>/dev/null || echo '[]')"
  orgs="$(gh api user/orgs --paginate --jq '.[].login' 2>/dev/null)"
  while IFS= read -r org; do
    [ -z "$org" ] && continue
    local o
    o="$(gh repo list "$org" --limit 200 --json nameWithOwner,description,isPrivate,isArchived,pushedAt,viewerPermission 2>/dev/null || echo '[]')"
    all="$(jq -c -n --argjson a "$all" --argjson b "$o" '$a + $b')"
  done <<EOF
$orgs
EOF

  jq -c -n --argjson r "$all" --argjson at "$(now_epoch)" '
    { at: $at,
      repos: ( $r
        | map(select(.isArchived != true))
        | unique_by(.nameWithOwner)
        # Repos you can actually merge in come first, then most recently pushed:
        # the one you want is nearly always in the first handful.
        | sort_by(
            (if (.viewerPermission // "") == "ADMIN" then 0
             elif (.viewerPermission // "") == "MAINTAIN" then 1
             elif (.viewerPermission // "") == "WRITE" then 2
             elif (.viewerPermission // "") == "TRIAGE" then 3
             else 4 end),
            (if .pushedAt then (.pushedAt | fromdateiso8601? // 0) * -1 else 0 end))
        | map({slug: .nameWithOwner, description: (.description // ""),
               private: (.isPrivate == true), permission: (.viewerPermission // ""),
               pushedAt: (.pushedAt // "")}) ) }' \
    | atomic_write "$cache"
}

repos_cache_read() {
  local cache d; cache="$(repos_cache_path)"
  d="$(cat "$cache" 2>/dev/null)"
  printf '%s' "$d" | jq -e . >/dev/null 2>&1 && printf '%s' "$d" || printf '{"at":0,"repos":[]}'
}

# goblin repos search [--json] [--query Q] [--limit N] [--refresh]
cmd_repos_search() {
  local as_json=false query="" limit=50 refresh=false
  while [ $# -gt 0 ]; do
    case "$1" in
      --json)    as_json=true; shift ;;
      --query|-q) query="${2:-}"; shift 2 ;;
      --limit)   limit="${2:-50}"; shift 2 ;;
      --refresh) refresh=true; shift ;;
      *) shift ;;
    esac
  done
  case "$limit" in ''|*[!0-9]*) limit=50 ;; esac
  [ "$limit" -gt 200 ] && limit=200
  [ "$limit" -lt 1 ] && limit=1

  local ttl age at
  ttl="$(cfg_get '.cache.reposTtlSecs' 3600)"
  at="$(repos_cache_read | jq -r '.at // 0')"
  age=$(( $(now_epoch) - ${at:-0} ))
  if [ "$refresh" = true ] || [ "${at:-0}" -eq 0 ] || [ "$age" -ge "${ttl:-3600}" ]; then
    engine_auth_lite >/dev/null 2>&1 || {
      [ "$as_json" = true ] && printf '{"error":"not authenticated","repos":[]}\n' \
        || echo "not signed in to GitHub — run: gh auth login" >&2
      return 1
    }
    repos_cache_fetch || true
  fi

  local out
  out="$(repos_cache_read | jq -c --arg q "$(lc "$query")" --argjson n "$limit" \
    --argjson have "$(cfg_get_json '[.repos[]?.slug]' '[]')" '
    { at: (.at // 0),
      repos: ( .repos
        | map(. + {watched: ((.slug) as $s | $have | index($s) != null)})
        | if $q == "" then . else
            map(select(((.slug|ascii_downcase) | contains($q))
                       or ((.description|ascii_downcase) | contains($q))))
          end
        | .[0:$n] ) }')"

  if [ "$as_json" = true ]; then printf '%s\n' "$out"; return 0; fi
  printf '%s' "$out" | jq -r '.repos[] |
    (if .watched then "* " else "  " end) + .slug
    + (if .private then "  (private)" else "" end)
    + (if .permission == "" then "" else "  " + (.permission|ascii_downcase) end)'
}

# --- one call for the wizard's first paint ---------------------------------
# Five subprocess spawns become one, and each piece stays independently testable.
cmd_wizard_state() {
  [ "${1:-}" = "state" ] && shift
  . "$LIB_DIR/providers.sh"

  local accounts providers repos_conf deps step
  accounts="$(cmd_accounts --json 2>/dev/null)"; [ -z "$accounts" ] && accounts='[]'
  providers="$(providers_probe_all 2>/dev/null)"; [ -z "$providers" ] && providers='[]'
  repos_conf="$(cfg_get_json '[.repos[]? | {slug, enabled: (.enabled != false)}]' '[]')"

  deps="$(jq -c -n \
    --argjson gh "$(command -v gh  >/dev/null 2>&1 && echo true || echo false)" \
    --argjson jq_ "$(command -v jq >/dev/null 2>&1 && echo true || echo false)" \
    --argjson git "$(command -v git >/dev/null 2>&1 && echo true || echo false)" \
    '{gh:$gh, jq:$jq_, git:$git}')"

  # Which screen to show first: the first thing that is actually missing.
  local login has_provider
  login="$(cfg_get '.identity.githubLogin' '')"
  has_provider="$(printf '%s' "$providers" | jq -r '[.[] | select(.available and .authed)] | length')"
  if   [ -z "$login" ];                     then step=account
  elif [ "${has_provider:-0}" -eq 0 ];      then step=provider
  elif [ -z "$(cfg_repos_enabled)" ];       then step=repos
  elif [ "$(cfg_get '.setupComplete' false)" != "true" ]; then step=review
  else step=ready
  fi

  jq -c -n --argjson a "$accounts" --argjson p "$providers" --argjson r "$repos_conf" \
    --argjson d "$deps" --arg step "$step" \
    --arg login "$login" --arg provider "$(cfg_get '.provider' claude)" \
    --argjson complete "$(cfg_get '.setupComplete' false)" \
    '{step:$step, deps:$d, accounts:$a, providers:$p,
      identity:{githubLogin:$login}, provider:$provider,
      repos:{configured:$r}, setup:{complete:$complete}}'
}
