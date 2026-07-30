# Setting up the Merge Goblin (10 minutes)

Send teammates this page. It assumes nothing.

## What he does

When someone requests **your** review on a pull request, the Goblin reviews it for you
and posts one comment: a summary, a verdict, and line-anchored notes on the specific
lines he has a problem with. He uses **an AI subscription you already have** (Claude,
ChatGPT/Codex or Cursor) — no API keys, no new bill.

He posts from **your GitHub account**, clearly labelled as automated. He never
approves and never blocks — it's advice, and your review request stays open.

## 1. Check you have the basics

```bash
gh --version   ||  brew install gh
jq --version   ||  brew install jq
gh auth status ||  gh auth login          # pick HTTPS, and your work account
```

## 2. Sign in to at least one AI CLI

Any one of these is enough. Use whichever seat your org gave you.

| | install | sign in |
|---|---|---|
| **Claude** | https://claude.ai/code | `claude` once, follow the prompt |
| **Codex** | `npm i -g @openai/codex` | `codex login` |
| **Cursor** | `curl https://cursor.com/install -fsS \| bash` | `cursor-agent login` |

Only Claude reports what a review costs in dollars. The others are covered by your
subscription, so the Goblin caps **reviews per run** instead.

## 3. Install him

```bash
git clone https://github.com/Kiril-P/merge-goblin.git && cd merge-goblin
./install.sh
```

He asks three things: which GitHub account to review as, which subscription to use,
and which repo to watch. Then he schedules himself every 15 minutes and drops
**Merge Goblin.app** in `~/Applications`.

If `~/.local/bin` isn't on your `PATH`, the installer tells you the line to add.

## 4. Open the control panel

Double-click **Merge Goblin.app**, or:

```bash
goblin ui
```

Everything lives there — no terminal needed after this point:

- the on/off switch, and snooze
- **which subscription reviews** (switch any time)
- daily spend cap, max reviews per run
- repos to watch
- teammates (see below)
- how loud he is, and what verdict he submits
- a health check with a **Fix** button
- every review he's posted, with cost

The panel runs only while the app is open. Quit the app (or `goblin ui --stop`) to
close it. The Goblin keeps reviewing on schedule either way — the panel is just the
window into him.

## 5. Try it before trusting it

```bash
goblin run --plan          # shows exactly what he'd do. Posts nothing.
```

Then pick one real PR and let him do it for real:

```bash
goblin run --pr 1234
```

Read what he posts. If the tone or threshold is off, say so — his rules come from the
repo's own review guide, so we can tune it for everyone at once.

## 6. Join the fleet

So that two of us never review the same PR, everyone lists the same teammates. In the
panel under **Teammates**, or:

```bash
goblin fleet add kiril && goblin fleet add alice && goblin fleet add bob
```

Each PR is then assigned to exactly one of us — `hash(pr + commit)` picks who — so the
work and the token spend spread out. A git ref lock enforces it even if someone's list
is out of date. If your Mac is asleep, someone else's Goblin picks up your PRs after
45 minutes.

**The list must match across the team.** Someone who's on the list but hasn't installed
him means their assigned PRs go unreviewed until the takeover window.

## When something looks wrong

```bash
goblin doctor          # tells you what's broken and the exact fix
goblin doctor --fix    # repairs the safe ones itself
goblin log -n 50       # what he's been doing
```

`goblin doctor` covers every failure this has actually hit: the wrong GitHub account
being active, a scratch clone left dirty, a provider not signed in, the scheduler not
loaded.

## Turning him off

| | |
|---|---|
| panel toggle, or `goblin off` | full stop, survives reboots |
| `goblin pause` | until next login |
| `goblin snooze 1h` | auto-resumes |
| daily cap in the panel | stops once today's spend passes it |
| `./uninstall.sh` | removes him, keeps your history |

## Worth knowing

- **macOS only** right now (he's scheduled with `launchd`).
- **He posts as you.** Every comment says it's automated and not your review, but your
  name is on it. If that's not OK for you, don't install him.
- **Subscription terms:** he drives interactive AI CLIs non-interactively. That may sit
  outside what those plans intend, and heavy use can hit rate limits.
- **He's only as good as the model.** Read his first few reviews rather than assuming.
- Nothing leaves your machine except to GitHub and the AI CLI you already use.
