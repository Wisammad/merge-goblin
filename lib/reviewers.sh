#!/usr/bin/env bash
# reviewers.sh — detect the coding agent, run independent reviewers in parallel,
# and merge their normalized findings into one review.

reviewer_label() {
  case "$1" in claude) printf 'Claude' ;; codex) printf 'OpenAI Codex' ;;
    cursor) printf 'Cursor' ;; *) printf '%s' "$1" ;; esac
}

# reviewers_plan <evidence.txt> <out.json>
#
# EVERY agent whose signature appears is a contributor, and none of them may
# review. Keeping only the highest-scoring one routed reviews straight back to a
# co-author: with Claude and Codex tied at one signature each, `-gt` is strict so
# Claude won on iteration order alone, and the plan then asked Codex — an actual
# author of the diff — to review its own work.
reviewers_plan() {
  local evidence="$1" out="$2" p pattern n one
  local contributors="" independent="" best="" best_n=0 signal=""
  local counts='{}' sigs='[]'

  for p in claude codex cursor; do
    case "$p" in
      claude) pattern='co-authored-by:.*(claude|anthropic)|noreply@anthropic\.com|generated (with|by).*claude|claude code' ;;
      codex)  pattern='co-authored-by:.*(codex|openai)|noreply@openai\.com|generated (with|by).*codex|written by codex' ;;
      cursor) pattern='co-authored-by:.*cursor|cursor(agent)?@|generated (with|by).*cursor|made with cursor' ;;
    esac
    n="$(grep -Eic "$pattern" "$evidence" 2>/dev/null || true)"; n="${n:-0}"
    counts="$(printf '%s' "$counts" | jq -c --arg p "$p" --argjson n "$n" '. + {($p):$n}')"
    if [ "$n" -gt 0 ]; then
      contributors="${contributors:+$contributors }$p"
      one="$(grep -Ei "$pattern" "$evidence" 2>/dev/null | head -1 | tr -d '\000-\037' | cut -c 1-180)"
      sigs="$(printf '%s' "$sigs" | jq -c --arg p "$p" --arg l "$(reviewer_label "$p")" \
        --argjson n "$n" --arg s "$one" '. + [{provider:$p,label:$l,matches:$n,signal:$s}]')"
      # `best` is now only the headline for the posted review; exclusion uses the
      # whole contributor set below.
      if [ "$n" -gt "$best_n" ]; then best="$p"; best_n="$n"; signal="$one"; fi
    else
      independent="${independent:+$independent }$p"
    fi
  done

  local n_ind=0; for p in $independent; do n_ind=$((n_ind + 1)); done

  local reviewers overrides='' note='' is_independent=true fallback
  if [ -z "$contributors" ]; then
    # Nothing to exclude. Two reviewers rather than all three: Claude Opus plus
    # the configured companion.
    fallback="$(cfg_get '.provider' 'codex')"
    [ "$fallback" = claude ] && fallback=codex
    reviewers="claude $fallback"; overrides='claude=opus'
  elif [ "$n_ind" -ge 2 ]; then
    reviewers="$independent"
  elif [ "$n_ind" -eq 1 ]; then
    reviewers="$independent"
    note="only $(reviewer_label "$independent") did not contribute here, so it reviewed alone"
  else
    # Every agent we can run contributed. There is no independent reviewer to be
    # had, so review with the least-involved one and say so in the posted review
    # rather than quietly presenting a self-review as an independent one.
    reviewers="$(printf '%s' "$counts" | jq -r 'to_entries | sort_by(.value) | .[0].key')"
    is_independent=false
    note="every available agent contributed to this PR; $(reviewer_label "$reviewers") had the fewest signatures and is reviewing its own work"
  fi

  local list='[]' override label
  for p in $reviewers; do
    override=""
    [ "$p" = claude ] && [ "$overrides" = 'claude=opus' ] && override=opus
    label="$(reviewer_label "$p")"
    [ "$p" = claude ] && [ "$override" = opus ] && label='Claude Opus 5'
    list="$(printf '%s' "$list" | jq -c --arg p "$p" --arg l "$label" --arg o "$override" \
      '. + [{provider:$p,label:$l,modelOverride:$o}]')"
  done

  jq -n --arg p "$best" --arg l "$(reviewer_label "$best")" --arg s "$signal" \
    --argjson n "$best_n" --argjson reviewers "$list" \
    --argjson contributors "$sigs" --argjson counts "$counts" \
    --argjson ind "$is_independent" --arg note "$note" \
    '{contributor:{detected:($p != ""),provider:$p,label:$l,matches:$n,signal:$s},
      contributors:$contributors, matchCounts:$counts,
      independent:$ind, note:$note, reviewers:$reviewers}' > "$out"
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
#
# Succeeds when AT LEAST ONE reviewer produced a review. Failing because a single
# provider was missing used to throw away the other's finished work: engine_review_pr
# short-circuits on a non-zero return, so a Claude-authored PR on a machine without
# cursor logged a failure, backed the head off through attempt_record so it would
# not be retried, and posted nothing — while codex sat there having completed.
reviewers_run() {
  local plan="$1" prompt="$2" dir="$3" work="$4" jobs="$work/reviewer-jobs" p override pid
  : > "$jobs"
  while IFS="$(printf '\t')" read -r p override; do
    [ -n "$p" ] || continue
    local reviewer_dir="$work/repo-$p"
    if ! reviewer_checkout "$dir" "$reviewer_dir"; then
      # Record it as this reviewer's failure and carry on. Returning here
      # abandoned reviewers already running in the background — their pids were
      # never waited on, so they were killed with the work dir.
      jq -n --arg p "$p" \
        '{provider:$p,ok:false,kind:"checkout",error:"could not stage a working copy"}' \
        > "$work/meta-$p.json"
      continue
    fi
    reviewer_run_one "$p" "$override" "$prompt" "$reviewer_dir" "$work" &
    pid=$!
    printf '%s\t%s\n' "$p" "$pid" >> "$jobs"
  done <<EOF
$(jq -r '.reviewers[] | [.provider,.modelOverride] | @tsv' "$plan")
EOF

  local ok=0 failed=0
  # `done < "$jobs"`, not a pipe: a pipe would run this in a subshell and the
  # counters would not survive it.
  while IFS="$(printf '\t')" read -r p pid; do
    if wait "$pid"; then ok=$((ok + 1)); else failed=$((failed + 1)); fi
  done < "$jobs"

  [ "$ok" -gt 0 ] && [ "$failed" -gt 0 ] \
    && log "  $failed reviewer(s) failed; continuing with the $ok that finished"
  [ "$ok" -gt 0 ]
}

# reviewers_merge <plan.json> <work-dir> <findings.json> <final-plan.json>
#
# A reviewer that failed keeps its metadata in the final plan — so the run record
# shows who was asked and why they did not answer — but contributes no findings.
# Slurping norm-<p>.json unconditionally aborted the whole merge for a provider
# that never wrote one, which turned one reviewer's absence into a total loss.
reviewers_merge() {
  local plan="$1" work="$2" out="$3" final="$4" merged="$work/merged-stage.json" p ok_any=false
  jq '. + {results:[]}' "$plan" > "$final"
  printf '{"schema_version":1,"summary":"","suggested_verdict":"comment","intent_notes":[],"findings":[]}' > "$merged"

  local meta norm ok
  for p in $(jq -r '.reviewers[].provider' "$plan"); do
    meta="$work/meta-$p.json"; norm="$work/norm-$p.json"; ok=false
    [ -s "$meta" ] || jq -n --arg p "$p" \
      '{provider:$p,ok:false,error:"reviewer never reported"}' > "$meta"
    [ "$(jq -r '.ok // false' "$meta" 2>/dev/null)" = true ] && [ -s "$norm" ] && ok=true

    # Metadata is folded in either way: a failure that leaves no trace is how you
    # end up staring at a half-empty review with nothing to explain it.
    jq --slurpfile m "$meta" --arg p "$p" '
      .reviewers |= map(if .provider == $p then . + {
        model:($m[0].model // $p), costUsd:($m[0].costUsd // 0), durationMs:($m[0].durationMs // 0),
        ok:($m[0].ok // false), error:($m[0].error // "")
      } else . end)
      | .results += [$m[0]]' "$final" > "$final.next" && mv "$final.next" "$final"

    [ "$ok" = true ] || continue
    ok_any=true
    jq --slurpfile r "$norm" --slurpfile m "$meta" --arg p "$p" '
      .summary += (if .summary == "" then "" else "\n\n" end)
        + "#### " + ($p | ascii_upcase) + " — independent review\n\n" + ($r[0].summary // "")
      | .findings += [ $r[0].findings[]? + {reviewer:$p, reviewerModel:($m[0].model // $p)} ]
      | .intent_notes += [($r[0].intent_note // empty) + {reviewer:$p}]
    ' "$merged" > "$merged.next" && mv "$merged.next" "$merged"
  done

  [ "$ok_any" = true ] || { log "  no reviewer produced a usable review"; return 1; }

  local max; max="$(cfg_get '.maxFindings' 25)"
  jq --argjson max "$max" '
    def rank: {blocker:0,convention:1,risk:2,question:3,nit:4}[.] // 9;
    # Two reviewers describing the SAME defect must collapse into one comment.
    # Grouping by .id could never do that: the id is a hash of path + title, and
    # independent models do not choose byte-identical titles. The proof was this
    # feature reviewing itself — codex called it "Continue when one reviewer
    # succeeds", cursor called it "Treat any reviewer failure as total failure",
    # same file, same line, and it posted two blockers for one bug.
    #
    # Position is the reliable join: same file, same side, same line is the same
    # defect in practice. Merging is lossless — every reviewer body is kept and
    # attributed — so the worst case for two genuinely distinct remarks on one
    # line is a single comment with two labelled paragraphs, which still beats
    # two comments. Findings with no line keep the old title-based key so that
    # file-level remarks do not all collapse into one.
    def mergekey:
      [ (.path // "repo"),
        (.side // "RIGHT"),
        (if (.line // 0) > 0 then (.line | tostring)
         else "t/" + (.title | ascii_downcase) end) ] | join(":");
    .findings = (
      .findings | group_by(mergekey) | map(
        sort_by(.severity | rank) as $g
        | ($g | map(.reviewer) | unique) as $who
        | $g[0] + {
            reviewers: ($g | map({provider:.reviewer,model:.reviewerModel}) | unique_by(.provider)),
            # Only attribute when more than one reviewer is in the group;
            # prefixing a lone reviewer with its own name is noise.
            body: (if ($who | length) <= 1 then ($g | map(.body) | join("\n\n"))
                   else ($g | map("**" + (.reviewer|ascii_upcase) + ":** " + .body) | join("\n\n")) end)
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
