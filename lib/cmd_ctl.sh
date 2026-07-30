#!/usr/bin/env bash
# cmd_ctl.sh — the small control verbs. Every mutation writes config AND status
# so the panel reflects it instantly, even when the agent is booted out and
# therefore cannot write status itself.

cmd_ctl() {
  local cmd="$1"; shift 2>/dev/null || true
  cfg_ensure

  case "$cmd" in
    off|disable-agent)
      cfg_set '.enabled=false'; agent_off
      status_set '{"state":"disabled","pausedReason":"manual","activity":""}'
      echo "$GOBLIN_EMOJI the $GOBLIN_SHORT has left his post (stays off across reboots — '$GOBLIN_SLUG on' to recall him)" ;;

    on|enable-agent)
      cfg_set '.enabled=true | .snoozeUntil=0'; agent_on
      status_set '{"state":"idle","pausedReason":"","activity":""}'
      echo "$GOBLIN_EMOJI the $GOBLIN_SHORT is on duty" ;;

    pause)
      cfg_set '.enabled=false'; agent_stop
      status_set '{"state":"paused","pausedReason":"manual","activity":""}'
      echo "paused (temporary — returns at next login; use '$GOBLIN_SLUG off' for a hard stop)" ;;

    resume)
      cfg_set '.enabled=true | .snoozeUntil=0'; agent_start
      status_set '{"state":"idle","pausedReason":"","activity":""}'
      echo "resumed" ;;

    toggle|toggle-power)
      if agent_disabled || [ "$(cfg_get '.enabled' true)" != "true" ]; then cmd_ctl on; else cmd_ctl off; fi ;;

    snooze|snooze1h|snoozetomorrow|clearsnooze)
      local until_ts
      case "${cmd}:${1:-}" in
        snooze1h:*)                   until_ts=$(( $(now_epoch) + 3600 )) ;;
        snoozetomorrow:*)             until_ts="$(tomorrow_epoch)" ;;
        clearsnooze:*)                until_ts=0 ;;
        snooze:1h)                    until_ts=$(( $(now_epoch) + 3600 )) ;;
        snooze:tomorrow)              until_ts="$(tomorrow_epoch)" ;;
        snooze:clear|snooze:)         until_ts=0 ;;
        *)                            until_ts=$(( $(now_epoch) + ${1:-3600} )) ;;
      esac
      cfg_set ".snoozeUntil=${until_ts}"
      if [ "$until_ts" -gt 0 ]; then
        status_set "$(jq -nc --argjson u "$until_ts" '{state:"snoozed",pausedReason:"snoozed",snoozeUntil:$u,activity:""}')"
        echo "snoozed until $(date -r "$until_ts" '+%H:%M')"
      else
        status_set '{"state":"idle","pausedReason":"","activity":""}'
        echo "snooze cleared"
      fi ;;

    budget|set-budget|budgetoff|budget2|budget5|budget10)
      local v
      case "$cmd" in
        budgetoff) v=0 ;; budget2) v=2 ;; budget5) v=5 ;; budget10) v=10 ;;
        *) v="${1:-show}" ;;
      esac
      if [ "$v" = "show" ]; then
        echo "daily cap: \$$(cfg_get '.budgetCapUsd' 0)  ·  spent today: \$$(today_spend)"
      else
        [ "$v" = "off" ] && v=0
        cfg_set ".budgetCapUsd=$(printf '%s' "$v" | jq -R 'tonumber? // 0')"
        status_set '{}'
        echo "daily cap set to \$$(cfg_get '.budgetCapUsd' 0)"
      fi ;;

    repos)
      local sub="${1:-list}"; shift 2>/dev/null || true
      case "$sub" in
        list|"") cfg_read | jq -r '.repos[]? | "\(if .enabled != false then "on " else "off" end)  \(.slug)"' ;;
        add)     cfg_repo_add "$1"; status_set '{}'; echo "added $1" ;;
        rm)      cfg_repo_rm "$1";  status_set '{}'; echo "removed $1" ;;
        enable)  cfg_repo_enable "$1" true;  status_set '{}'; echo "enabled $1" ;;
        disable) cfg_repo_enable "$1" false; status_set '{}'; echo "disabled $1" ;;
        *) echo "usage: $GOBLIN_SLUG repos [list|add SLUG|rm SLUG|enable SLUG|disable SLUG]" >&2; return 2 ;;
      esac ;;

    provider)
      local sub="${1:-which}"; shift 2>/dev/null || true
      . "$LIB_DIR/providers.sh"
      case "$sub" in
        list)  providers_report ;;
        use)   providers_set "$1" ;;
        which|"") echo "$(cfg_get '.provider' claude) ($(cfg_get ".providers.$(cfg_get '.provider' claude).model" 'default model'))" ;;
        *) echo "usage: $GOBLIN_SLUG provider [list|use <id>|which]" >&2; return 2 ;;
      esac ;;

    fleet)
      local sub="${1:-list}"; shift 2>/dev/null || true
      case "$sub" in
        list|"") cfg_read | jq -r '.fleet[]?' ;;
        add) cfg_set --arg l "$1" 'if (.fleet | index($l)) then . else .fleet += [$l] end'; echo "fleet: $(cfg_read | jq -r '.fleet | join(", ")')" ;;
        rm)  cfg_set --arg l "$1" '.fleet |= map(select(. != $l))'; echo "fleet: $(cfg_read | jq -r '.fleet | join(", ")')" ;;
        *) echo "usage: $GOBLIN_SLUG fleet [list|add LOGIN|rm LOGIN]" >&2; return 2 ;;
      esac ;;

    config)
      local sub="${1:-path}"; shift 2>/dev/null || true
      case "$sub" in
        path|"") echo "$CONFIG" ;;
        get)     cfg_read | jq -r "${1:-.}" ;;
        set)     cfg_set "$1 = $(printf '%s' "$2" | jq -R 'tonumber? // (if . == "true" then true elif . == "false" then false else . end)')" && cfg_read | jq -r "$1" ;;
        edit)    "${EDITOR:-open}" "$CONFIG" ;;
        *) echo "usage: $GOBLIN_SLUG config [get <jq-path>|set <jq-path> <value>|edit|path]" >&2; return 2 ;;
      esac ;;

    log)
      case "${1:-}" in
        -f) tail -f "$LOG" ;;
        -n) tail -n "${2:-50}" "$LOG" ;;
        *)  tail -n 50 "$LOG" ;;
      esac ;;

    agent)
      case "${1:-status}" in
        status) echo "label:    $AGENT_LABEL"
                echo "plist:    $AGENT_PLIST"
                echo "running:  $(agent_running && echo yes || echo no)"
                echo "disabled: $(agent_disabled && echo yes || echo no)" ;;
        start)  agent_start;  echo "started" ;;
        stop)   agent_stop;   echo "stopped" ;;
        reload) agent_reload; echo "reloaded" ;;
        label)  echo "$AGENT_LABEL" ;;
        *) echo "usage: $GOBLIN_SLUG agent [status|start|stop|reload|label]" >&2; return 2 ;;
      esac ;;

    fix-account)
      local want; want="$(goblin_login)"
      [ -z "$want" ] && { echo "no login configured" >&2; return 1; }
      gh auth switch --user "$want" >/dev/null 2>&1 && echo "active github account is now $want"
      status_set '{}' ;;

    run-now)
      nohup "$GOBLIN_APP/bin/$GOBLIN_SLUG" run --scheduled >/dev/null 2>&1 &
      echo "started a run in the background" ;;

    *) echo "$GOBLIN_SLUG: unknown control verb '$cmd'" >&2; return 2 ;;
  esac
}
