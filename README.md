# 👺 The Merge Goblin

**He guards the merge button — reviewing the pull requests that ask for your review, on the AI subscription you already pay for.**

He watches for PRs where you're a requested reviewer, reads the repo's *own* review
guidelines, and posts one clearly-labelled automated review with line-anchored comments —
plus a second comment answering "does this actually do what the ticket asked?"

Commit signatures identify whether Claude, Codex, or Cursor contributed the code. The other
two agents then review independently in parallel, and the GitHub review names the contributor
signal and both reviewer/model routes. With no recognized signature, the fallback is Claude
Opus 5 plus the configured companion provider (OpenAI Codex by default).

> ### The Goblin refuses the merge.
> `claude/sonnet` · inspected `aa309fb` — 12 files, +1976 −296 against `main`
>
> **🔴 1 blocker · 🟠 2 convention**

He is a desktop control panel and a CLI, running on your Mac, on your schedule, on
your account — nothing is sent anywhere except to the AI CLI you already use.

---

## Why

Hosted review bots are per-seat and send your code to another vendor. Meanwhile your team
already has Claude, ChatGPT and Cursor seats sitting there. The Goblin drives two of those CLIs
in parallel, so a review costs nothing beyond the subscriptions you're already paying for.

- **Your subscription, not an API key.** `claude`, `codex` or `cursor-agent`, whichever is installed.
- **One review, not twenty notifications.** All findings in a single grouped review.
- **Reads your repo's rules.** If the repo has review guidelines, he follows them. No config needed.
- **Never approves, never blocks.** Advisory by default, and it says so in every comment.
- **Never double-reviews.** Several teammates can run him; exactly one reviews each PR.
- **A real off switch.** One toggle in the panel, plus snooze and a daily spend cap.

## Install

> Handing this to a teammate? Send them **[docs/TEAM-SETUP.md](docs/TEAM-SETUP.md)** —
> it assumes nothing and takes about ten minutes.

Requires macOS, [`gh`](https://cli.github.com), `jq`, and at least one AI CLI you're signed into.

```bash
git clone https://github.com/Kiril-P/merge-goblin.git && cd merge-goblin
./install.sh
```

The installer asks which account to review as, which subscription to use, and which repo to
watch, then schedules him and installs the control panel. Re-run it any time to upgrade.

Upgrading is always those two commands — `git pull && ./install.sh`. The Goblin checks once a
day whether a newer version exists and says so in the panel, in `goblin doctor` and in the log,
but he never installs it himself: that would mean rewriting the code mid-run and reloading the
scheduler behind your back. Turn the check off with `goblin config set .update.notify false`.

```bash
brew install gh jq                      # if you need them
```

The installer also drops **Merge Goblin.app** in `~/Applications` — a menu bar app that
shows what he's doing, which PRs are waiting for you, and lets you change everything below
without touching a terminal. Turn on **Start at login** from its menu and it's there every
morning.

It's compiled on your machine from `app/` (about ten seconds, AppKit and WebKit only) and
ad-hoc signed, so there is no Xcode project, nothing to notarise and no Gatekeeper prompt.
`xcode-select --install` is all it needs; if `swiftc` is missing the installer skips the app
and says so, because the CLI works without it.

```bash
goblin app rebuild          # after editing share/ui/panel.css or app/*.swift
goblin app status           # bundle, login item, whether it's running
```

## Use

Most people only need the menu bar app. There's also a browser panel, which is
the fallback if the app won't build:

```bash
goblin ui                   # the browser panel on 127.0.0.1
```

Everything is adjustable there: the on/off switch, snooze, which subscription
reviews, model, spend caps, repos, teammates, verdict policy, notifications, plus
a health check with a one-click **Fix** button and your review history.

The CLI does the same things, if you prefer:

```bash
goblin status                  # where things stand
goblin run --plan              # dry run: show exactly what would be posted, post nothing
goblin run --pr 123            # review one PR right now
goblin --auto                  # watch your open PRs everywhere; review each new head
goblin --auto owner/name       # same watcher, limited to one repo
goblin https://github.com/owner/name/pull/123  # review that PR until a pass finds nothing new
goblin https://github.com/owner/name/pull/123 --once   # ...or just once
goblin run --pr 123 --repo owner/name --until-clean    # the same sweep, without a link
goblin run --repo owner/name --force           # review every open PR in one repo, now
goblin doctor                  # diagnose anything odd (--fix repairs the safe stuff)

goblin off / goblin on            # master switch (off survives reboots)
goblin snooze 1h               # temporary quiet
goblin budget 5                # stop after $5/day

goblin provider list           # which subscriptions are ready
goblin provider use codex      # choose the companion for unknown-contributor fallback
goblin repos add owner/name    # watch another repo

goblin update                  # is there a newer Goblin? (tells you; installs nothing)
```

Start with **`goblin run --plan`**. It assembles the real prompt and shows you the diff,
the review rules it found and the lines it can comment on — without calling a model.

`goblin --auto` is a foreground watcher: leave it running and stop it with Ctrl-C. It
looks only at PRs authored by your configured GitHub user, across every repository that
account can see. Each distinct PR head is reviewed once. Set `GOBLIN_WATCH_INTERVAL`
to change the 30-second check interval. `--auto owner/name` limits the same user-scoped
watch to one repository.

To review one PR right now, paste its GitHub URL straight after `goblin` — the link
from your browser's address bar, tracking parameters and `#files` anchor included. It
runs immediately, regardless of the automatic scope. For a whole repository at once,
`goblin run --repo owner/name --force`.

### The sweep

A pasted link does not review once — it **keeps reviewing until a pass finds nothing
new**. Each pass reads the findings already on the PR, tells the reviewers not to raise
them again, and posts only what is new, so the passes converge: the pass that adds
nothing is the pass that says the PR is clean. It is the manual "run it again to see
what else is in there" loop, automated.

It stops on the first of:

- a pass that raises no finding the sweep has not already seen — **clean**
- a pass that fails, or that is refused by the daily review cap or the spend cap
- the PR merging or closing underneath it
- `maxPassesPerPr` passes (default **5**)

Every pass is a real review, so it spends a `maxReviewsPerDay` slot and, on a metered
provider, real money. Tune or turn it off:

```bash
goblin config set .maxPassesPerPr 8      # allow more passes per sweep
goblin config set .sweepUntilClean false # a pasted link reviews once again
goblin <PR_URL> --once                   # just this once
goblin run --pr 123 --repo o/n --until-clean --max-passes 3
```

Exact-PR audits can run concurrently in separate terminals. Different PRs use isolated
temporary checkouts; a second audit of the same PR is skipped to prevent duplicate reviews.
Parallel audits can consume AI-provider quota faster than sequential reviews.

## What he posts

A single review, from your account, that cannot be mistaken for you:

> ![Merge Goblin](https://img.shields.io/badge/👺%20Merge%20Goblin-guards%20the%20merge%20button-2f6f3e?style=flat-square&labelColor=1b3d24)
>
> ### The Goblin smells an unhandled exception.
> `claude/sonnet` · inspected `fd4e602` — 12 files, +142 −38 against `main`
>
> **🟠 2 convention · 🟡 1 risk**
>
> …summary…
>
> ---
> <sub>👺 posted automatically by the **Merge Goblin** running on @you's machine — this is
> **not** a human review from @you. advisory only: it neither approves nor blocks.</sub>

His verdict line tells you how bad it is before you read a word:

| | |
|---|---|
| no findings | *Suspiciously clean. Proceed.* |
| findings, none blocking | *The Goblin smells an unhandled exception.* |
| a blocker | *The Goblin refuses the merge.* |
| approved (opt-in) | *The Goblin approves this offering.* |

Plus inline comments on the exact lines, and an intent check against the linked issue.

## How it decides what to look for

The Goblin uses **your repo's existing review guidance**, in this order:

1. `.goblin/config.json` → `{"promptPath": "..."}` (`.bob/` still honoured)
2. a review skill under `.agents/skills/*pr-review*/SKILL.md`
3. `.github/PULL_REQUEST_REVIEW.md`, `.github/CODE_REVIEW.md`, `CONTRIBUTING.md`
4. convention sections your guide points at (e.g. a named section of `AGENTS.md`)
5. a built-in general-purpose reviewer prompt

He keeps your rules on *what to flag and how to write*, and ignores anything about *how to
submit* — the Goblin owns posting, so severity and verdict are enforced in code rather than trusted
to the model.

## Running it as a team

Everyone installs the Goblin and lists the same teammates:

```bash
goblin fleet add alice && goblin fleet add bob && goblin fleet add carol
```

For each PR, `hash(pr + commit) % fleet` picks exactly one owner, so the work — and the token
spend — spreads evenly instead of landing on whoever's laptop is awake. Before reviewing,
the assigned Goblin takes an **atomic lock** (a git ref, which GitHub creates exactly once), so even if
two configs disagree a PR is never reviewed twice. If the owner's machine is asleep, another
Goblin picks it up after a grace period.

## Cost and control

Only Claude reports real dollar cost; the subscription CLIs report usage but not money, so
he also caps **reviews per run**. Everything is visible in the panel and `goblin status`.

| control | what it does |
|---|---|
| `goblin off` | stops the scheduler entirely, survives reboot |
| `goblin pause` | temporary; returns at next login |
| `goblin snooze 1h` / `tomorrow` | auto-resumes |
| `goblin budget 5` | pause for the day once today's spend passes $5 |
| `maxReviewsPerRun` | hard stop per cycle, so a backlog can't run away |

## Configuration

`~/.goblin/config.json` — edit with `goblin config set <jq-path> <value>`, `goblin config edit`, or the panel.

| key | default | |
|---|---|---|
| `provider` | `claude` | `claude` · `codex` · `cursor` |
| `providers.cursor.model` | `cursor-grok-4.6-high` | any id `cursor-agent models` lists; blank lets the CLI pick |
| `providerFallback` | `[]` | try these if the main one is out of quota |
| `verdictMode` | `comment` | `comment` · `request-changes` · `full` |
| `allowApprove` | `false` | second opt-in required before he can ever approve |
| `budgetCapUsd` | `10` | 0 = unlimited |
| `maxReviewsPerRun` | `5` | |
| `maxFindings` | `25` | |
| `sweepUntilClean` | `true` | a pasted PR link re-reviews until a pass finds nothing new |
| `maxPassesPerPr` | `5` | ceiling on those passes; each one is a real review |
| `fleet` | `[]` | teammates also running the Goblin |
| `intervalSeconds` | `300` | re-run `install.sh` after changing |

## How it works

```
launchd ──▶ goblin run ──▶ pick PRs ──▶ assign ──▶ claim (git ref)
                                                    │
                       repo's review rules ─┐       ▼
                       annotated diff ──────┼──▶ two reviewer CLIs ──▶ merged findings JSON
                       linked issue ────────┘                              │
                                                                           ▼
                                          validate ▸ drop unpostable lines ▸
                                          one grouped review + intent comment
```

The reviewers never receive GitHub credentials and return JSON; the Goblin alone does the
posting. Each parallel reviewer gets an isolated temporary checkout, so a tool-capable CLI
cannot affect the other review.

State lives in `~/.goblin/`: `config.json`, `events.jsonl` (history and spend), `ledger`
(what's been reviewed), `repos/` (scratch clones), `goblin.log`.

## Uninstall

```bash
./uninstall.sh            # send him home, keep history
./uninstall.sh --purge    # remove everything
```

## Notes

- **macOS only** (uses `launchd`). Bash 3.2 + `jq`. The optional control panel uses
  the `python3` that ships with Xcode's command line tools — no packages to install.
- **He posts under your GitHub account.** Subscription CLIs have no bot identity, so every
  artifact is labelled and disclaims being your review. He never approves or requests
  changes unless you explicitly opt in twice.
- **On subscription terms:** he drives interactive AI CLIs non-interactively. That may sit
  outside what those plans intend, and heavy use can hit rate limits. Check your plan; use
  it deliberately.
- Reviews are only as good as the model and the repo's guidelines. Read the first few and
  tune `maxFindings` / the repo prompt.

## Development

```bash
./tests/run.sh            # offline: fake gh/claude/launchctl, no network, no cost
shellcheck bin/goblin lib/*.sh lib/providers/*.sh
GOBLIN_HOME=/tmp/gtest ./install.sh --non-interactive --no-agent --no-app --home /tmp/gtest
goblin ui --no-open --port 8790     # panel without launching a browser
goblin ui --stop                   # shut a running panel down
```

The panel is `share/ui/app.html` (one file, no framework) served by
`share/ui/server.py` (stdlib only). Every button shells out to the `goblin` CLI, so
there is exactly one implementation of every action.

Adding a provider is one file in `lib/providers/` implementing `probe` and `review`.
Renaming him is one file: `lib/brand.sh`.

MIT licensed.
