#!/usr/bin/env bash
# brand.sh — the one place the product's identity lives.
#
# Everything derives from these, so a rename is a one-file change: the CLI name,
# the state directory, the launchd label, the git-ref lock namespace, the hidden
# comment markers and every string the Goblin says.

GOBLIN_NAME="The Merge Goblin"     # how it introduces itself
GOBLIN_SHORT="Merge Goblin"        # when "The" reads badly mid-sentence
GOBLIN_SLUG="goblin"               # cli name, state dir, ref namespace, label
GOBLIN_VERSION="0.4.1"
GOBLIN_TAGLINE="guards the merge button"
GOBLIN_EMOJI="👺"
GOBLIN_REPO_URL="https://github.com/Kiril-P/merge-goblin"
# Derived, never written twice: the update check asks GitHub for this repo's
# brand.sh and compares the GOBLIN_VERSION it finds against the one above.
GOBLIN_REPO_SLUG="${GOBLIN_REPO_URL#https://github.com/}"

# Hidden HTML marker prefix. Every artifact the Goblin posts carries one of:
#   <!-- goblin:review  {...} -->   the grouped review body
#   <!-- goblin:finding {...} -->   an inline comment
#   <!-- goblin:intent  {...} -->   the "does this do what the ticket asked" comment
#   <!-- goblin:claim   {...} -->   fallback claim comment (only if git refs are refused)
# Markers are the ONLY reliable machine identity: it runs under a human's user
# token, so GitHub reports user.type "User" — there is no [bot] suffix to match.
GOBLIN_MARKER_NS="$GOBLIN_SLUG"
# Reviews posted before the rename still carry the old prefix. Keep matching it
# or the Goblin would forget what it had already reviewed and post duplicates.
GOBLIN_MARKER_NS_LEGACY="bob"

# Severity vocabulary. The order here IS the display/sort order.
GOBLIN_SEVERITIES="blocker convention risk nit question"

goblin_severity_label() {
  case "$1" in
    blocker)    printf '%s' "🔴 blocker" ;;
    convention) printf '%s' "🟠 convention" ;;
    risk)       printf '%s' "🟡 risk" ;;
    nit)        printf '%s' "⚪ nit" ;;
    question)   printf '%s' "🔵 question" ;;
    *)          printf '%s' "• $1" ;;
  esac
}

# --- the Goblin's voice ----------------------------------------------------
# SCOPE: the Goblin speaks in the REVIEW HEADER ONLY. Inline findings stay in a
# plain professional register — they are the working surface a developer reads
# while deciding whether to change code, and character there costs credibility.
# render_inline_body deliberately carries nothing but a severity chip and an
# attribution footer. Keep it that way.
#
# One line per verdict, so a reviewer can tell at a glance how bad it is before
# reading a word of detail. Each line must be TRUE of the counts that produced
# it: an earlier revision announced "smells an unhandled exception" over a
# single em-dash convention hit, which reads as noise and trains people to skip
# the header.
#   goblin_verdict_line <blockers> <total> <event>
goblin_verdict_line() {
  local blockers="${1:-0}" total="${2:-0}" event="${3:-COMMENT}"
  if [ "$event" = "APPROVE" ]; then
    printf '%s' "The Goblin approves this offering."
  elif [ "${blockers:-0}" -gt 0 ] 2>/dev/null; then
    printf '%s' "The Goblin refuses the merge."
  elif [ "${total:-0}" -gt 0 ] 2>/dev/null; then
    printf '%s' "The Goblin has notes."
  else
    printf '%s' "Suspiciously clean. Proceed."
  fi
}

# Shorter versions for notifications and the control panel.
goblin_mood() {
  local blockers="${1:-0}" total="${2:-0}"
  if   [ "${blockers:-0}" -gt 0 ] 2>/dev/null; then printf '%s' "refuses the merge"
  elif [ "${total:-0}" -gt 0 ] 2>/dev/null;    then printf '%s' "has notes"
  else                                              printf '%s' "suspiciously clean"
  fi
}
