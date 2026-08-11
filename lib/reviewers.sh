#!/usr/bin/env bash
# reviewers.sh — detect the coding agent, run independent reviewers in parallel,
# and merge their normalized findings into one review.

reviewer_label() {
  case "$1" in claude) printf 'Claude' ;; codex) printf 'OpenAI Codex' ;;
    cursor) printf 'Cursor' ;; *) printf '%s' "$1" ;; esac
}

# reviewers_plan <evidence.txt> <out.json>
reviewers_plan() {
  local evidence="$1" out="$2" p pattern n best="" best_n=0 signal="" reviewers overrides fallback
  for p in claude codex cursor; do
    case "$p" in
      claude) pattern='co-authored-by:.*(claude|anthropic)|noreply@anthropic\.com|generated (with|by).*claude|claude code' ;;
      codex)  pattern='co-authored-by:.*(codex|openai)|noreply@openai\.com|generated (with|by).*codex|written by codex' ;;
      cursor) pattern='co-authored-by:.*cursor|cursor(agent)?@|generated (with|by).*cursor|made with cursor' ;;
    esac
    n="$(grep -Eic "$pattern" "$evidence" 2>/dev/null || true)"
    if [ "${n:-0}" -gt "$best_n" ]; then
      best="$p"; best_n="$n"
      signal="$(grep -Ei "$pattern" "$evidence" 2>/dev/null | head -1 | tr -d '\000-\037' | cut -c 1-180)"
    fi
  done

  case "$best" in
    claude) reviewers='codex cursor'; overrides='' ;;
    codex)  reviewers='claude cursor'; overrides='' ;;
    cursor) reviewers='claude codex'; overrides='' ;;
    *)      fallback="$(cfg_get '.provider' 'codex')"
            [ "$fallback" = claude ] && fallback=codex
            reviewers="claude $fallback"; overrides='claude=opus' ;;
  esac

  local list='[]' override label
  for p in $reviewers; do
    override=""
    [ "$p" = claude ] && [ "$overrides" = 'claude=opus' ] && override=opus
    label="$(reviewer_label "$p")"
    [ "$p" = claude ] && [ "$override" = opus ] && label='Claude Opus 5'
    list="$(printf '%s' "$list" | jq --arg p "$p" --arg l "$label" --arg o "$override" \
      '. + [{provider:$p,label:$l,modelOverride:$o}]')"
  done

  jq -n --arg p "$best" --arg l "$(reviewer_label "$best")" --arg s "$signal" \
    --argjson n "$best_n" --argjson reviewers "$list" \
    '{contributor:{detected:($p != ""),provider:$p,label:$l,matches:$n,signal:$s},reviewers:$reviewers}' > "$out"
}

reviewer_run_one() {
  local provider="$1" override="$2" prompt="$3" dir="$4" work="$5"
  local raw="$work/raw-$provider" out="$work/norm-$provider.json" meta="$work/meta-$provider.json"
  mkdir -p "$raw"

  local probe; probe="$("provider_${provider}_probe" 2>/dev/null)"
  if [ "$(printf '%s' "$probe" | jq -r '.available and .authed')" != true ]; then
    jq -n --arg p "$provider" --arg e "$(printf '%s' "$probe" | jq -r '.note // "provider unavailable"')" \
      '{provider:$p,ok:false,error:$e}' > "$meta"
    return 1
  fi

  if [ -n "$override" ]; then export GOBLIN_MODEL_OVERRIDE="$override"
  else unset GOBLIN_MODEL_OVERRIDE
  fi
  if findings_run "$provider" "$prompt" "$dir" "$out" "$raw"; then
    jq -n --arg p "$provider" --arg m "${GOBLIN_P_MODEL:-$provider}" \
      --argjson cost "${GOBLIN_P_COST_USD:-0}" --argjson ms "${GOBLIN_P_DURATION_MS:-0}" \
      '{provider:$p,ok:true,model:$m,costUsd:$cost,durationMs:$ms}' > "$meta"
    return 0
  fi
  jq -n --arg p "$provider" --arg e "${GOBLIN_P_ERRMSG:-review failed}" \
    --arg k "${GOBLIN_P_ERRKIND:-other}" '{provider:$p,ok:false,kind:$k,error:$e}' > "$meta"
  return 1
}

reviewer_checkout() {
  local source="$1" dest="$2" sha
  mkdir -p "$dest"
  if git -C "$source" rev-parse --git-dir >/dev/null 2>&1; then
    sha="$(git -C "$source" rev-parse HEAD 2>/dev/null)"
    rmdir "$dest" 2>/dev/null || true
    git clone --quiet --shared --no-checkout "$source" "$dest" >/dev/null 2>&1 \
      && git -C "$dest" checkout --quiet --detach "$sha" >/dev/null 2>&1 \
      && return 0
  fi
  # Diff-only fallback: the prompt already contains the complete review input.
  mkdir -p "$dest"
}

# reviewers_run <plan.json> <prompt> <repo-dir> <work-dir>
reviewers_run() {
  local plan="$1" prompt="$2" dir="$3" work="$4" jobs="$work/reviewer-jobs" p override pid rc=0
  : > "$jobs"
  while IFS="$(printf '\t')" read -r p override; do
    [ -n "$p" ] || continue
    local reviewer_dir="$work/repo-$p"
    reviewer_checkout "$dir" "$reviewer_dir" || return 1
    reviewer_run_one "$p" "$override" "$prompt" "$reviewer_dir" "$work" &
    pid=$!
    printf '%s\t%s\n' "$p" "$pid" >> "$jobs"
  done <<EOF
$(jq -r '.reviewers[] | [.provider,.modelOverride] | @tsv' "$plan")
EOF

  while IFS="$(printf '\t')" read -r p pid; do
    wait "$pid" || rc=1
  done < "$jobs"
  return "$rc"
}

# reviewers_merge <plan.json> <work-dir> <findings.json> <final-plan.json>
reviewers_merge() {
  local plan="$1" work="$2" out="$3" final="$4" merged="$work/merged-stage.json" p
  jq '. + {results:[]}' "$plan" > "$final"
  printf '{"schema_version":1,"summary":"","suggested_verdict":"comment","intent_notes":[],"findings":[]}' > "$merged"

  for p in $(jq -r '.reviewers[].provider' "$plan"); do
    jq --slurpfile r "$work/norm-$p.json" --slurpfile m "$work/meta-$p.json" --arg p "$p" '
      .summary += (if .summary == "" then "" else "\n\n" end)
        + "#### " + ($p | ascii_upcase) + " — independent review\n\n" + ($r[0].summary // "")
      | .findings += [ $r[0].findings[]? + {reviewer:$p, reviewerModel:($m[0].model // $p)} ]
      | .intent_notes += [($r[0].intent_note // empty) + {reviewer:$p}]
    ' "$merged" > "$merged.next" && mv "$merged.next" "$merged"
    jq --slurpfile m "$work/meta-$p.json" --arg p "$p" '
      .reviewers |= map(if .provider == $p then . + {
        model:($m[0].model // $p), costUsd:($m[0].costUsd // 0), durationMs:($m[0].durationMs // 0)
      } else . end)
      | .results += [$m[0]]' "$final" > "$final.next" && mv "$final.next" "$final"
  done

  local max; max="$(cfg_get '.maxFindings' 25)"
  jq --argjson max "$max" '
    def rank: {blocker:0,convention:1,risk:2,question:3,nit:4}[.] // 9;
    .findings = (
      .findings | group_by(.id) | map(
        sort_by(.severity | rank) as $g
        | $g[0] + {
            reviewers: ($g | map({provider:.reviewer,model:.reviewerModel}) | unique_by(.provider)),
            body: (if ($g|length) == 1 then $g[0].body else
              ($g | map("**" + (.reviewer|ascii_upcase) + ":** " + .body) | join("\n\n")) end)
          }
        | del(.reviewer,.reviewerModel)
      ) | sort_by(.severity | rank) | .[0:$max]
    )
    | .intent_note = (
        if (.intent_notes|length) == 0 then null else
          .intent_notes as $notes
          | {issue: ($notes | map(.issue // "") | map(select(. != "")) | first // ""),
             verdict: ($notes | map(.verdict // "unknown")
               | sort_by({diverges:0,partial:1,unknown:2,fulfils:3,no_ticket:4}[.] // 5) | first),
             body: ($notes | map("**" + (.reviewer|ascii_upcase) + ":** " + (.body // "")) | join("\n\n"))}
        end)
    | del(.intent_notes)
  ' "$merged" > "$out"
}
