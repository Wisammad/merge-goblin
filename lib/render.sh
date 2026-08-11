#!/usr/bin/env bash
# render.sh — the Goblin's voice.
#
# These reviews post from a HUMAN's GitHub account (subscription CLIs have no bot
# identity), so every artifact has to work hard to not be mistaken for that
# person's own review:
#   1. it opens as the Goblin, naming the model that wrote it
#   2. it closes by naming the account and explicitly disclaiming it
#   3. it never uses first person about the code
# The hidden marker on each artifact is what makes re-runs idempotent.

# A badge acts as the avatar: GitHub comments can't reference a private repo's
# SVG, and shields.io is already how the other bots on these PRs identify.
goblin_badge() {
  printf '![%s](https://img.shields.io/badge/%s-%s-2f6f3e?style=flat-square&labelColor=1b3d24)' \
    "$GOBLIN_SHORT" \
    "$(printf '%s' "$GOBLIN_EMOJI $GOBLIN_SHORT" | sed 's/ /%20/g')" \
    "$(printf '%s' "${1:-automated review}" | sed 's/ /%20/g')"
}

goblin_footer() {
  local login="$1" extra="${2:-}"
  printf '<sub>%s posted automatically by the **%s** running on @%s'"'"'s machine — this is **not** a human review from @%s. advisory only: it neither approves nor blocks. re-runs on every push.%s</sub>' \
    "$GOBLIN_EMOJI" "$GOBLIN_SHORT" "$login" "$login" "${extra:+ $extra}"
}

# render_marker <type> <json-object>
render_marker() { printf '<!-- %s:%s %s -->' "$GOBLIN_MARKER_NS" "$1" "$(printf '%s' "$2" | jq -c .)"; }

# render_counts <findings.json> — "🔴 1 blocker · 🟠 2 convention"
render_counts() {
  local out
  out="$(jq -r -f "$SHARE_DIR/jq/counts.jq" "$1" 2>/dev/null)"
  # Never return empty: this goes straight into the review body, and a silent
  # failure here once shipped a literal "****" to a real pull request.
  if [ -n "$out" ]; then printf '%s' "$out"; else printf 'findings below'; fi
}

# render_inline_body <finding-json> <provider> <model> <pr> <head>
render_inline_body() {
  local f="$1" provider="$2" model="$3" pr="$4" head="$5"
  local sev title body sug marker agents
  sev="$(printf '%s'   "$f" | jq -r '.severity')"
  title="$(printf '%s' "$f" | jq -r '.title')"
  body="$(printf '%s'  "$f" | jq -r '.body')"
  sug="$(printf '%s'   "$f" | jq -r '.suggestion // ""')"

  agents="$(printf '%s' "$f" | jq -c '.reviewers // []' 2>/dev/null)"
  marker="$(render_marker finding "$(jq -nc \
    --arg id "$(printf '%s' "$f" | jq -r '.id')" --arg sev "$sev" --arg m "$model" \
    --argjson pr "$pr" --arg head "$head" --argjson reviewers "${agents:-[]}" \
    '{v:1,id:$id,pr:$pr,headSha:$head,severity:$sev,model:$m,reviewers:$reviewers}')")"

  printf '%s\n%s **%s**\n\n%s\n' "$marker" "$(goblin_severity_label "$sev")" "$title" "$body"
  # A suggestion block only renders as applyable if it replaces exactly the
  # commented range, so only emit one when the model gave a clean replacement.
  if [ -n "$sug" ] && [ "$sug" != "null" ]; then
    printf '\n```suggestion\n%s\n```\n' "$sug"
  fi
  if [ "$(printf '%s' "${agents:-[]}" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null; then
    printf '\n<sub>%s %s · independently reported by %s</sub>' "$GOBLIN_EMOJI" "$GOBLIN_SHORT" \
      "$(printf '%s' "$agents" | jq -r 'map("`" + .provider + "/" + .model + "`") | join(" + ")')"
  else
    printf '\n<sub>%s %s · `%s/%s`</sub>' "$GOBLIN_EMOJI" "$GOBLIN_SHORT" "$provider" "$model"
  fi
}

# render_review_body <norm.json> <split.json> <pr> <head> <base> <provider> <model> <login> <files.json> <event>
render_review_body() {
  local norm="$1" split="$2" pr="$3" head="$4" base="$5" provider="$6" model="$7" login="$8" files="$9"
  local event="${10:-COMMENT}" plan="${11:-}"
  local ids counts adds dels blockers total

  ids="$(jq -c '[.findings[].id]' "$norm" 2>/dev/null)"
  counts="$(jq -c '[.findings[]?.severity] | group_by(.) | map({key: .[0], value: length}) | from_entries' "$norm" 2>/dev/null)"
  adds="$(jq '[.[].additions] | add // 0' "$files" 2>/dev/null)"
  dels="$(jq '[.[].deletions] | add // 0' "$files" 2>/dev/null)"
  blockers="$(jq '[.findings[]? | select(.severity=="blocker")] | length' "$norm" 2>/dev/null)"
  total="$(jq '.findings | length' "$norm" 2>/dev/null)"

  render_marker review "$(jq -nc \
    --arg bot "$GOBLIN_SHORT" --arg p "$provider" --arg m "$model" --argjson pr "$pr" \
    --arg head "$head" --arg by "$login" --argjson at "$(now_epoch)" \
    --argjson counts "${counts:-{\}}" --argjson ids "${ids:-[]}" \
    '{v:1,type:"review",bot:$bot,provider:$p,model:$m,pr:$pr,headSha:$head,by:$by,at:$at,counts:$counts,findingIds:$ids}')"
  printf '\n%s\n\n' "$(goblin_badge "$GOBLIN_TAGLINE")"

  if [ -n "$plan" ] && jq -e '.reviewers | length > 0' "$plan" >/dev/null 2>&1; then
    local detected contributor matches signal routed
    detected="$(jq -r '.contributor.detected' "$plan")"
    contributor="$(jq -r '.contributor.label // ""' "$plan")"
    matches="$(jq -r '.contributor.matches // 0' "$plan")"
    signal="$(jq -r '.contributor.signal // ""' "$plan" | tr -d '\000-\037' | cut -c 1-180)"
    routed="$(jq -r '[.reviewers[] | "**" + .label + "** (`" + (.model // .provider) + "`)"] | join(" and ")' "$plan")"
    if [ "$detected" = true ]; then
      printf '> **Coding-agent contributor detected:** **%s** from %s signature match(es)' "$contributor" "$matches"
      [ -n "$signal" ] && printf ': `%s`' "$signal"
      printf '.\n>\n'
    else
      printf '> **Coding-agent contributor:** no recognized signature; using the Claude Opus 5 fallback route.\n>\n'
    fi
    printf '> **Independent reviewers asked in parallel:** %s. The findings below merge both reviews.\n\n' "$routed"
  fi

  # The verdict line first — it tells a reader how bad this is before they read
  # a single finding.
  printf '### %s\n\n' "$(goblin_verdict_line "${blockers:-0}" "${total:-0}" "$event")"
  printf '`%s/%s` · inspected `%s` — %s files, +%s −%s against `%s`\n\n' \
    "$provider" "$model" "$(trunc "$head" 7)" \
    "$(jq 'length' "$files" 2>/dev/null)" "$adds" "$dels" "$base"
  printf '**%s**\n\n' "$(render_counts "$norm")"

  local summary; summary="$(jq -r '.summary // ""' "$norm")"
  [ -n "$summary" ] && printf '%s\n\n' "$summary"

  # Findings that couldn't be anchored to a diff line are reported here rather
  # than silently dropped.
  local ndem; ndem="$(jq '.demoted | length' "$split" 2>/dev/null || echo 0)"
  if [ "${ndem:-0}" -gt 0 ]; then
    printf '<details><summary><b>%s finding(s) the Goblin could not pin to a diff line</b></summary>\n\n' "$ndem"
    jq -r '.demoted[] | "- `\(.path // "repo")\(if .line then ":\(.line)" else "" end)` — **\(.title)**\n\n  \(.body | gsub("\n"; "\n  "))\n"' \
      "$split" 2>/dev/null
    printf '\n</details>\n\n'
  fi

  printf -- '---\n%s\n' "$(goblin_footer "$login")"
}

# render_intent_body <intent-json> <pr> <head> <provider> <model> <login>
render_intent_body() {
  local intent="$1" pr="$2" head="$3" provider="$4" model="$5" login="$6"
  local issue verdict body vlabel
  issue="$(printf '%s'   "$intent" | jq -r '.issue // ""')"
  verdict="$(printf '%s' "$intent" | jq -r '.verdict // "unknown"')"
  body="$(printf '%s'    "$intent" | jq -r '.body // ""')"

  case "$verdict" in
    fulfils)  vlabel="✅ the offering matches what was asked" ;;
    partial)  vlabel="🟡 the offering is incomplete" ;;
    diverges) vlabel="🔴 this is not what was asked for" ;;
    *)        vlabel="❔ the Goblin could not tell" ;;
  esac

  render_marker intent "$(jq -nc --argjson pr "$pr" --arg head "$head" --arg i "$issue" \
    --arg v "$verdict" --arg m "$model" --arg by "$login" --argjson at "$(now_epoch)" \
    '{v:1,type:"intent",pr:$pr,headSha:$head,issue:$i,verdict:$v,model:$m,by:$by,at:$at}')"
  printf '\n%s\n\n' "$(goblin_badge "intent check")"
  printf '### %s\n\n' "$vlabel"
  printf 'does this pull request do what its issue asked? · `%s/%s`\n' "$provider" "$model"
  [ -n "$issue" ] && printf '\nissue: **%s**\n' "$issue"
  printf '\n%s\n\n' "$body"
  printf -- '---\n%s\n' "$(goblin_footer "$login" 'updated in place on each push.')"
}
