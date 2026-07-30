#!/usr/bin/env bash
# providers.sh — the provider registry. The engine talks only to this file, so
# adding a new AI CLI means dropping one adapter into lib/providers/.

GOBLIN_PROVIDERS="claude codex cursor"

providers_load() {
  local p
  for p in $GOBLIN_PROVIDERS; do
    # shellcheck source=/dev/null
    [ -f "$PROVIDER_DIR/$p.sh" ] && . "$PROVIDER_DIR/$p.sh"
  done
}

# Map a CLI's error text onto a stable kind so the engine can react (a quota
# error should fall back to another provider; a transient one should retry).
provider_classify_error() {
  local t; t="$(lc "${1:-}")"
  case "$t" in
    *"rate limit"*|*"quota"*|*"usage limit"*|*"too many requests"*|*429*) echo quota ;;
    *"not logged in"*|*"unauthorized"*|*"authentication"*|*"invalid api key"*|*401*) echo auth ;;
    *"timeout"*|*"timed out"*|*"econnreset"*|*"network"*|*"socket"*|*5[0-9][0-9]*) echo transient ;;
    "") echo other ;;
    *) echo other ;;
  esac
}

providers_probe_all() {
  providers_load
  local p out=""
  for p in $GOBLIN_PROVIDERS; do
    out="$out$("provider_${p}_probe" 2>/dev/null)
"
  done
  printf '%s' "$out" | jq -s '.'
}

providers_report() {
  local cur; cur="$(cfg_get '.provider' 'claude')"
  providers_probe_all | jq -r --arg cur "$cur" '.[] |
    (if .name == $cur then "▸ " else "  " end) +
    (.name | . + (" " * (8 - length))) +
    (if .available then (if .authed then "ready  " else "no auth" end) else "missing" end) +
    "  " + ((.authMode // "") | .[0:14] | . + (" " * (16 - length))) +
    (if .costKnown then "cost: yes" else "cost: n/a" end) +
    (if (.note // "") != "" then "   " + .note else "" end)'
}

providers_set() {
  local want="$1" ok=false p
  for p in $GOBLIN_PROVIDERS; do [ "$p" = "$want" ] && ok=true; done
  if [ "$ok" != true ]; then
    echo "unknown provider '$want' (choose: $GOBLIN_PROVIDERS)" >&2; return 2
  fi
  providers_load
  local probe; probe="$("provider_${want}_probe")"
  if [ "$(printf '%s' "$probe" | jq -r '.available')" != "true" ]; then
    echo "$want is not installed: $(printf '%s' "$probe" | jq -r '.note')" >&2; return 1
  fi
  if [ "$(printf '%s' "$probe" | jq -r '.authed')" != "true" ]; then
    echo "warning: $want is installed but not authenticated — $(printf '%s' "$probe" | jq -r '.note')" >&2
  fi
  cfg_set --arg p "$want" '.provider = $p'
  status_set '{}'
  echo "provider set to $want"
}

# The provider to use for this run: the configured one if usable, else the first
# healthy entry in providerFallback. Prints the chosen id, or nothing.
providers_pick() {
  providers_load
  local want fallbacks p probe
  want="$(cfg_get '.provider' 'claude')"
  probe="$("provider_${want}_probe" 2>/dev/null)"
  if [ "$(printf '%s' "$probe" | jq -r '.available and .authed')" = "true" ]; then
    printf '%s' "$want"; return 0
  fi
  fallbacks="$(cfg_read | jq -r '.providerFallback[]?' 2>/dev/null)"
  for p in $fallbacks; do
    probe="$("provider_${p}_probe" 2>/dev/null)"
    if [ "$(printf '%s' "$probe" | jq -r '.available and .authed')" = "true" ]; then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}
