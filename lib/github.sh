#!/usr/bin/env bash
# github.sh — all reads from GitHub. Writes live in post.sh, locking in claim.sh.

# gh_prs <slug> <out.json>
# One core-API call (5000/hr) instead of the search API (30/min), and it returns
# everything fleet assignment needs. Team review requests carry no `login` key,
# so entries are normalised to {kind,key} rather than assuming a user.
gh_prs() {
  local slug="$1" out="$2"
  gh pr list --repo "$slug" --state open --limit 100 \
    --json number,headRefOid,isDraft,title,url,baseRefName,author,reviewRequests,updatedAt,createdAt \
    2>/dev/null \
  | jq '[ .[] | {
      number, head: .headRefOid, draft: .isDraft, title, url,
      base: .baseRefName, author: (.author.login // ""),
      updatedAt: (.updatedAt | fromdateiso8601? // 0),
      createdAt: (.createdAt | fromdateiso8601? // 0),
      requested: [ .reviewRequests[]?
        | if .__typename == "Team"
          then {kind:"team", key: ((.organization.login // "") + "/" + (.slug // .name // ""))}
          else {kind:"user", key: (.login // "")} end
        | select(.key != "" and .key != "/") ]
    } ]' > "$out" 2>/dev/null
  jq -e 'type == "array"' "$out" >/dev/null 2>&1 || { echo '[]' > "$out"; return 1; }
}

# gh_user_prs <login> <out.json>
# Find open PRs authored by one user across every repository visible to the
# active GitHub account. Search supplies repo/number pairs; the pull endpoint
# supplies the current head and the same normalized shape as gh_prs.
gh_user_prs() {
  local login="$1" out="$2" search="$RUNTMP/user-pr-search-$$.json" rows="$out.rows"
  : > "$rows"

  gh api --paginate --slurp -X GET search/issues \
    -f q="is:pr is:open archived:false author:$login" -f per_page=100 \
    > "$search" 2>/dev/null || { echo '[]' > "$out"; rm -f "$search" "$rows"; return 1; }

  jq -r '
    (if type == "array" then [.[].items[]?] else [.items[]?] end)[]
    | [(.repository_url | split("/") | .[-2:] | join("/")), (.number | tostring)]
    | @tsv' "$search" 2>/dev/null \
  | while IFS="$(printf '\t')" read -r slug pr; do
      [ -n "$slug" ] && [ -n "$pr" ] || continue
      gh api "repos/$slug/pulls/$pr" 2>/dev/null \
      | jq -c --arg repo "$slug" '{
          repo: $repo, number, head: .head.sha, draft: (.draft // false),
          title, url: .html_url, base: .base.ref, author: (.user.login // ""),
          updatedAt: (.updated_at | fromdateiso8601? // 0),
          createdAt: (.created_at | fromdateiso8601? // 0),
          requested: (
            [ .requested_reviewers[]? | {kind:"user", key:(.login // "")} ] +
            [ .requested_teams[]? | {kind:"team", key:((.organization.login // "") + "/" + (.slug // .name // ""))} ]
            | map(select(.key != "" and .key != "/"))
          )
        }' >> "$rows" 2>/dev/null
    done

  jq -s 'unique_by(.repo + "#" + (.number | tostring))' "$rows" > "$out" 2>/dev/null \
    || echo '[]' > "$out"
  rm -f "$search" "$rows" 2>/dev/null
  jq -e 'type == "array"' "$out" >/dev/null 2>&1
}

# Expand a team slug to member logins, cached for a day (read:org scope needed).
gh_team_members() {
  local org_team="$1" cache="$GOBLIN_HOME/teams.json" org slug now
  org="${org_team%%/*}"; slug="${org_team##*/}"
  now="$(now_epoch)"
  if [ -f "$cache" ]; then
    local age members
    age="$(jq -r --arg k "$org_team" '.[$k].at // 0' "$cache" 2>/dev/null)"
    if [ "$(( now - ${age:-0} ))" -lt 86400 ]; then
      members="$(jq -r --arg k "$org_team" '.[$k].members[]?' "$cache" 2>/dev/null)"
      [ -n "$members" ] && { printf '%s\n' "$members"; return 0; }
    fi
  fi
  local list
  list="$(gh api --paginate "orgs/$org/teams/$slug/members?per_page=100" --jq '.[].login' 2>/dev/null)"
  [ -z "$list" ] && return 1
  local arr; arr="$(printf '%s\n' "$list" | jq -R . | jq -s .)"
  local cur='{}'; [ -f "$cache" ] && cur="$(cat "$cache" 2>/dev/null)"
  printf '%s' "$cur" | jq --arg k "$org_team" --argjson m "$arr" --argjson at "$now" \
    '.[$k] = {at:$at, members:$m}' > "$cache.tmp" 2>/dev/null && mv "$cache.tmp" "$cache"
  printf '%s\n' "$list"
}

# gh_pr_is_open <slug> <pr> — 0 if still open, 1 if merged/closed or unknown.
#
# `gh pr list` is a snapshot taken at the top of a run. A busy repo merges
# inside that window: PR #1441 merged at 12:32:27 and the review landed at
# 12:38:14, six minutes into a closed PR, where all three findings went unread.
# One cheap call before the model runs (and again before posting) is worth more
# than the review it prevents.
gh_pr_is_open() {
  local state
  state="$(gh api "repos/$1/pulls/$2" --jq '.state + (if .merged then "/merged" else "" end)' 2>/dev/null)"
  # An API blip must not silently suppress a legitimate review, so treat an
  # empty answer as "still open" and let the post itself fail if it is not.
  [ -z "$state" ] && return 0
  case "$state" in open) return 0 ;; *) return 1 ;; esac
}

# gh_pr_meta <slug> <pr> <out.json> — body + head sha for the prompt.
gh_pr_meta() {
  gh api "repos/$1/pulls/$2" \
    --jq '{number, title, body, base: .base.ref, head: .head.sha, headRef: .head.ref, author: .user.login, url: .html_url}' \
    > "$3" 2>/dev/null
}

# Evidence used only to identify a coding-agent contributor. Commit trailers are
# strongest; PR text and branch names catch agents that disclose elsewhere.
gh_pr_agent_evidence() {
  local slug="$1" pr="$2" prjson="$3" out="$4"
  jq -r '.title // "", .body // "", .headRef // ""' "$prjson" 2>/dev/null > "$out"
  gh api --paginate "repos/$slug/pulls/$pr/commits?per_page=100" \
    --jq '.[].commit.message' >> "$out" 2>/dev/null || true
}

# gh_prior_review <slug> <pr> — the most recent review marker on this PR, or empty.
# Read from GitHub (not local state) so a fresh machine still knows what was posted.
# Matches the pre-rename prefix too, else a rename would make the Goblin forget
# every review it had already posted and duplicate all of them.
gh_prior_review() {
  gh api --paginate "repos/$1/pulls/$2/reviews?per_page=100" --jq '
    [ .[]
      | select(.body != null)
      | (.body | capture("<!-- (?<ns>'"$GOBLIN_MARKER_NS"'|'"$GOBLIN_MARKER_NS_LEGACY"'):review (?<j>\\{.*?\\}) -->") // empty) as $c
      | { submitted_at, commit_id, m: ($c.j | fromjson) } ]
    | sort_by(.submitted_at) | last // empty' 2>/dev/null
}

# gh_reviews_fetch <slug> <pr> <dest> — the raw reviews array, to a file.
#
# A file rather than a pipe because two callers want two different questions
# answered from the same page of results (has a human reviewed this, and what did
# the Goblin last say), and paying for the round trip twice per PR per poll adds up
# fast on a repo with twenty open PRs. Fails if the response is not an array, so a
# rate-limit error object can never be read as "no reviews".
gh_reviews_fetch() {
  gh api --paginate "repos/$1/pulls/$2/reviews?per_page=100" > "$3" 2>/dev/null || return 1
  jq -e 'type == "array"' "$3" >/dev/null 2>&1 || return 1
}

# gh_human_reviewers <reviews-file> — logins of real people who have reviewed.
#
# Three exclusions, each one a wrong answer we have seen:
#   * PENDING reviews are drafts only their author can see
#   * bots, by user.type and by the "[bot]" suffix, because a review from another
#     automation is not a human having looked at this
#   * the Goblin's OWN reviews, which are posted under a human token and so are
#     indistinguishable from that human's reviews except by the hidden marker.
#     Without this the Goblin sees its own review, concludes a human is on it, and
#     never reviews that repo again.
gh_human_reviewers() {
  jq -r --arg me "${GOBLIN_LOGIN:-}" \
        --arg ns "$GOBLIN_MARKER_NS" '
    [ .[]
      | select((.state // "") != "PENDING")
      | select(((.user.type // "") | ascii_downcase) != "bot")
      | select(((.user.login // "") | test("\\[bot\\]$")) | not)
      | select(
          ((.user.login // "") | ascii_downcase) != ($me | ascii_downcase)
          or ((.body // "") | test("<!-- " + $ns + ":review ") | not)
        )
      | .user.login ]
    | unique | .[]' "$1" 2>/dev/null
}

# gh_prior_findings <slug> <pr> — ids/titles already posted inline, for dedupe.
# `.line` can be null on outdated comments (only the deprecated `position`
# survives), so fall back to original_line.
gh_prior_findings() {
  gh api --paginate "repos/$1/pulls/$2/comments?per_page=100" --jq '
    [ .[]
      | . as $c
      | select(.body != null)
      | (.body | capture("<!-- (?<ns>'"$GOBLIN_MARKER_NS"'|'"$GOBLIN_MARKER_NS_LEGACY"'):finding (?<j>\\{.*?\\}) -->") // empty) as $mk
      | ($mk.j | fromjson)
        + { commentId: $c.id, path: $c.path, line: ($c.line // $c.original_line) } ]' 2>/dev/null
}

# gh_find_comment <slug> <pr> <marker-type> — id of an existing comment, for upsert.
gh_find_comment() {
  gh api --paginate "repos/$1/issues/$2/comments?per_page=100" --jq \
    "[.[] | select(.body != null and ((.body | contains(\"$GOBLIN_MARKER_NS:$3\")) or (.body | contains(\"$GOBLIN_MARKER_NS_LEGACY:$3\")))) | .id] | first // empty" 2>/dev/null
}

# gh_ticket_context <slug> <pr> <pr.json> <out>
# Pull the linked issue's text so the intent check reviews against what was
# actually asked. No Linear API needed: the PR body carries the link, and the
# Linear GitHub app posts a linkback comment that embeds the full description.
gh_ticket_context() {
  local slug="$1" pr="$2" prjson="$3" out="$4"
  : > "$out"
  local body key url
  body="$(jq -r '.body // ""' "$prjson" 2>/dev/null)"
  key="$(printf '%s' "$body" | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' | head -1)"
  url="$(printf '%s' "$body" | grep -oE 'https://linear\.app/[^) ]+' | head -1)"

  local linkback
  linkback="$(gh api --paginate "repos/$slug/issues/$pr/comments?per_page=100" \
    --jq '[.[] | select(.body != null and (.body | test("linear-linkback|linear\\.app")))
           | .body] | first // empty' 2>/dev/null)"

  if [ -n "$key" ] || [ -n "$linkback" ]; then
    { [ -n "$key" ] && printf 'Issue: %s\n' "$key"
      [ -n "$url" ] && printf 'Link: %s\n' "$url"
      if [ -n "$linkback" ]; then
        printf '\nIssue description (from the tracker):\n\n'
        printf '%s\n' "$linkback" | sed 's/<[^>]*>//g' | head -c 6000
      fi
    } > "$out"
  fi
  printf '%s' "$key"
}

# gh_status <slug> <sha> <state> <desc> [url] — SHA-scoped visible marker.
gh_status() {
  [ "$(cfg_get '.postCommitStatus' true)" = "true" ] || return 0
  local slug="$1" sha="$2" state="$3" desc="$4" url="${5:-}"
  set -- -f state="$state" -f context="$GOBLIN_SLUG/review" -f description="$(trunc "$desc" 138)"
  [ -n "$url" ] && set -- "$@" -f target_url="$url"
  gh api -X POST "repos/$slug/statuses/$sha" "$@" --silent >/dev/null 2>&1 || true
}
