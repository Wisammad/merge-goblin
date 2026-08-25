# Autonomous re-review sweep + Grok 4.6 for Cursor

## Goal
1. `goblin <PR_URL>` keeps re-reviewing the PR until a pass finds nothing new,
   instead of needing a manual restart per pass.
2. The Cursor adapter reviews with Grok 4.6 instead of the CLI's auto pick.

## Why a loop converges at all
Each pass reads the findings already posted on the PR (`gh_prior_findings`),
lists them in the prompt as "do not report these again", and filters any that
come back by id. So a pass posts only what is *new*. The pass that adds nothing
is the pass that says the PR is clean. That is exactly the manual restart loop,
automated.

## Design decisions
- **A fresh process per pass**, same as `cmd_auto` already does for its cycles.
  In-process iteration would carry `REVIEWS_THIS_RUN`, the EXIT trap and the
  claim/reservation state of pass 1 into pass 2 — `maxReviewsPerRun` (5) alone
  would have silently capped every sweep with no explanation.
- **The pass reports back through a file** named by `GOBLIN_PASS_RESULT`, created
  per pass by the parent. Missing or unparseable file = stop. Fail-safe: the loop
  only ever continues on an explicit `posted` with `findings > 0`.
- **Every other outcome stops the loop** — failure, quota, budget, merged, claimed
  elsewhere. Never spin on a no-op.
- **Cap it.** `maxPassesPerPr` (default 5). Each pass is a real review: it spends a
  `maxReviewsPerDay` slot and real money on a metered provider.
- **Cursor's model moves via a schema migration**, not an adapter fallback.
  `cfg_backfill_defaults` never overwrites an existing value, and `""` *is* a
  value — so a changed default can otherwise never reach an install that already
  exists. Schema v3 rewrites only an empty cursor model, so an explicit choice
  (including a deliberate "the CLI's default") survives.

## Tasks
- [x] `lib/config.sh`: schema v3, `cfg_migrate_values`, `sweepUntilClean`,
      `maxPassesPerPr`, cursor model default
- [x] `lib/brand.sh`: `GOBLIN_CURSOR_DEFAULT_MODEL` constant
- [x] `lib/providers/cursor.sh`: honour `GOBLIN_MODEL_OVERRIDE`; retry without
      `--model` when the CLI rejects the id
- [x] `lib/engine.sh`: `engine_sweep`, `engine_sweep_pass`, `engine_pass_write`,
      `--until-clean` / `--once` / `--max-passes`, sweep by default from `cmd_url`
- [x] `lib/engine.sh`: fixed-replies gated on the head actually changing
- [x] `bin/goblin`, `share/ui/panel.js`, `README.md`
- [x] `tests/run.sh` — 15 new tests
- [x] `./tests/run.sh` green (120 passed), bash 3.2 parse, jq compile, no new
      shellcheck warnings

## Review

### What shipped
`goblin <PR_URL>` now sweeps: it re-reviews the PR in a fresh process per pass
until a pass raises no finding the sweep has not already seen. `--once` opts out,
`sweepUntilClean: false` opts out permanently, `maxPassesPerPr` (5) caps it.
`goblin run --pr N --repo R --until-clean [--max-passes N]` is the same thing
without a link. Cursor reviews with `cursor-grok-4.6-high`.

### Three problems found while building, all fixed
1. **The loop could not have converged on part of its input.** GitHub-side dedupe
   reads the *inline* comments on a PR. A finding on a line outside the diff is
   never an inline comment — it is demoted into the review body with its marker
   stripped, so the next pass cannot see it and would raise it again forever.
   The sweep therefore tracks finding ids itself and stops when a pass carries
   nothing new, rather than trusting a per-pass count.
2. **Pre-existing: every incremental re-review lied about what was fixed.**
   `post_fixed_replies` replies "✅ no longer flagged" on each prior thread
   missing from the new findings — but the new findings had the prior ones
   deliberately removed upstream, so *all* of them looked resolved. A sweep would
   have done this on every pass, marking live bugs fixed. Now gated on the head
   commit actually having changed: no new commit, nothing fixed.
3. **Pre-existing: the EXIT trap aborted mid-list.** `pr_lock_release` read an
   unset `PR_LOCKDIR` under `set -u` on any exact-PR run that returned before
   taking a lock, so the `reservation_release` and `lock_release` queued behind
   it never ran — the crash-safety net silently stopped catching. Initialised
   and read with a default.

Plus one bug in my own first draft, caught by writing the test for it: handing
back to `cmd_run` from inside a sweep left `UNTIL_CLEAN` set, so `cmd_run` walked
straight back into `engine_sweep` until the stack blew.
`test_sweep_handoff_does_not_re_enter_itself` fails without the fix.

### Deliberately not done
- **Not exposed in the control panel.** `settings` there is an explicit key
  projection with a validated write verb per field; the two new keys are
  CLI/config-only for now (documented in the README).
- **Findings still post one review event per pass.** That mirrors the manual
  restart loop being replaced and keeps GitHub as the source of truth for what
  was already said. Accumulating passes locally and posting once would be one
  event instead of N, but changes what a "review" costs in quota accounting.
- **The `post_fixed_replies` signal is still weak on a genuinely new head** —
  an obedient model does not re-report a prior finding, so absence cannot
  distinguish "fixed" from "told not to mention it". Only the same-commit case,
  which the sweep creates, is fixed here.
- **CI's shellcheck step is red on `main`** (8 SC2155/SC2318 warnings on
  pre-existing lines; SC2318 postdates the code). This branch adds none —
  8 before, 8 after — but it does not clear them either.
