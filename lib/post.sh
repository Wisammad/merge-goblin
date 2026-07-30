#!/usr/bin/env bash
# post.sh — everything the Goblin writes to GitHub.
#
# One grouped review, never N. The old design let the model call `gh pr review`
# itself, which produced six separate review events on a single PR; here the
# whole review is one API call with a comments[] array.

# post_build_review <split.json> <body.md> <head> <event> <provider> <model> <pr> <out.json>
post_build_review() {
  local split="$1" bodyfile="$2" head="$3" event="$4" provider="$5" model="$6" pr="$7" out="$8"

  # Render each inline comment body, keeping only the fields GitHub accepts.
  local comments="[]" i n f rendered
  n="$(jq '.inline | length' "$split" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    f="$(jq -c --argjson i "$i" '.inline[$i]' "$split")"
    rendered="$(render_inline_body "$f" "$provider" "$model" "$pr" "$head")"
    comments="$(printf '%s' "$comments" | jq \
      --argjson f "$f" --arg body "$rendered" '
      . + [ ({ path: $f.path, line: $f.line, side: ($f.side // "RIGHT"), body: $body })
            + ( if ($f.start_line != null) and ($f.start_line != $f.line)
                then { start_line: $f.start_line, start_side: ($f.start_side // $f.side // "RIGHT") }
                else {} end ) ]')"
    i=$((i + 1))
  done

  # A jq failure anywhere in that loop blanks the accumulator, and every later
  # iteration then appends to nothing. That silently shipped a review whose body
  # announced "2 blocker, 1 convention" with zero findings attached (PR #1442).
  # The count is the contract: if it does not hold, refuse to build the payload.
  local got
  got="$(printf '%s' "$comments" | jq 'length' 2>/dev/null)"
  if [ "${got:-x}" != "${n:-0}" ]; then
    log "  BUG: rendered ${got:-0} of ${n:-0} inline comment(s) — refusing to post a review that under-reports"
    return 1
  fi

  # commit_id is pinned: without it GitHub defaults to the latest commit, so a
  # push mid-review would silently re-anchor every comment.
  # body is mandatory for COMMENT/REQUEST_CHANGES; event must be set or the
  # review is created as PENDING and never appears.
  jq -n --arg commit "$head" --rawfile body "$bodyfile" --arg event "$event" \
        --argjson comments "$comments" \
    '{commit_id:$commit, body:$body, event:$event, comments:$comments}' > "$out"
}

# post_fold_into_body <payload.json> <out.json> [indices-json]
# Move comments into the review body as an appendix, so a finding that cannot be
# anchored is still READ. Without this the fallback ladder below destroys the
# findings it drops while the body keeps advertising them in the count line.
# Omit <indices-json> to fold every comment.
post_fold_into_body() {
  local payload="$1" out="$2" which="${3:-}"
  jq --argjson which "${which:-null}" '
    ( if $which == null then [ range(0; (.comments // []) | length) ] else $which end ) as $idx
    | ( [ (.comments // []) | to_entries[] | select(.key as $i | $idx | index($i)) | .value ] ) as $moved
    | if ($moved | length) == 0 then .
      else
        .body += (
          "\n\n<details><summary><b>" + (($moved | length) | tostring) +
          " finding(s) GitHub would not anchor to a diff line</b></summary>\n\n" +
          ( [ $moved[]
              | "- `" + (.path // "repo") + (if .line then ":" + (.line | tostring) else "" end) + "`\n\n"
                + ( (.body // "")
                    # Strip the hidden marker: a marker in the body would make the
                    # next run treat this appendix as an already-posted thread.
                    | gsub("<!--[^>]*-->"; "")
                    | sub("^\\s+"; "")
                    | gsub("\n"; "\n  ") )
                + "\n" ] | join("\n") ) +
          "\n</details>\n" )
        | .comments |= [ to_entries[] | select(.key as $i | ($idx | index($i)) | not) | .value ]
      end' "$payload" > "$out" 2>/dev/null
}

# post_review <slug> <pr> <review.json> <errfile> -> prints review html_url
# Ladder: full → drop the entries GitHub named → body-only. Never split into
# multiple reviews; that is the spam pattern this design exists to remove.
post_review() {
  local slug="$1" pr="$2" payload="$3" errf="$4" resp
  if resp="$(gh api -X POST "repos/$slug/pulls/$pr/reviews" --input "$payload" 2>"$errf")"; then
    printf '%s' "$resp" | jq -r '.html_url // ""'; return 0
  fi

  # Each rung DEMOTES the comments it cannot place into the body. A finding is
  # only ever allowed to lose its line anchor, never to disappear.
  local bad
  bad="$(jq -r '[.errors[]? | .index // empty] | @json' "$errf" 2>/dev/null)"
  if [ -n "$bad" ] && [ "$bad" != "[]" ] && [ "$bad" != "null" ]; then
    log "  review rejected; demoting $(printf '%s' "$bad" | jq 'length') unmappable comment(s) into the body"
    if post_fold_into_body "$payload" "$payload.2" "$bad" && [ -s "$payload.2" ]; then
      if resp="$(gh api -X POST "repos/$slug/pulls/$pr/reviews" --input "$payload.2" 2>"$errf")"; then
        printf '%s' "$resp" | jq -r '.html_url // ""'; return 0
      fi
    fi
  fi

  # Last resort: no inline comments at all — but every finding moves into the
  # body first, so the review still says everything it found.
  log "  inline comments rejected entirely — demoting all findings into the body"
  if ! post_fold_into_body "$payload" "$payload.3" || [ ! -s "$payload.3" ]; then
    log "  could not demote findings into the body — refusing to post a review that would lose them"
    return 1
  fi
  if resp="$(gh api -X POST "repos/$slug/pulls/$pr/reviews" --input "$payload.3" 2>"$errf")"; then
    printf '%s' "$resp" | jq -r '.html_url // ""'; return 0
  fi
  return 1
}

# post_intent <slug> <pr> <body.md> — upsert, so a re-review edits in place
# instead of stacking comments (the pattern the Linear/Vercel apps use here).
post_intent() {
  local slug="$1" pr="$2" bodyfile="$3" id
  [ "$(cfg_get '.postIntentComment' true)" = "true" ] || return 0
  id="$(gh_find_comment "$slug" "$pr" intent)"
  if [ -n "$id" ]; then
    gh api -X PATCH "repos/$slug/issues/comments/$id" -F body=@"$bodyfile" --silent >/dev/null 2>&1
  else
    gh api -X POST "repos/$slug/issues/$pr/comments" -F body=@"$bodyfile" --silent >/dev/null 2>&1
  fi
}

# post_fixed_replies <slug> <pr> <prior.json> <current-ids.json> <head>
# Reply on threads whose finding is gone from the new run. Replies are comment
# replies, not review events, so they don't recreate the multi-event spam.
post_fixed_replies() {
  local slug="$1" pr="$2" prior="$3" curids="$4" head="$5"
  local gone i n cid
  gone="$(jq -c --slurpfile cur "$curids" \
    '[ .[] | select(.id != null) | select(($cur[0] | index(.id)) == null) ] | .[0:10]' \
    "$prior" 2>/dev/null)"
  n="$(printf '%s' "$gone" | jq 'length' 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "${n:-0}" ]; do
    cid="$(printf '%s' "$gone" | jq -r --argjson i "$i" '.[$i].commentId')"
    if [ -n "$cid" ] && [ "$cid" != "null" ]; then
      gh api -X POST "repos/$slug/pulls/$pr/comments/$cid/replies" \
        -f body="✅ no longer flagged as of \`$(trunc "$head" 7)\` — $GOBLIN_NAME" \
        --silent >/dev/null 2>&1 || true
    fi
    i=$((i + 1))
  done
}
