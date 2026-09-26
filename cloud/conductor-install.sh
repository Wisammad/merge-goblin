#!/usr/bin/env bash
# Conductor Cloud Computer install script (Settings → Organization → Cloud Computer).
# Runs at image build. Installs cursor-agent and goblin, plus a `goblin` wrapper
# that finishes setup on first use inside a workspace, where Conductor has logged
# `gh` in as whoever owns the workspace.
#
# Environment (Cloud Computer → Environment), all optional except one provider:
#   CURSOR_API_KEY   cursor-agent auth (the default provider)
#   OPENAI_API_KEY   seeds `codex login --with-api-key` once per sandbox
#   GOBLIN_PROVIDER  claude | codex | cursor   (default: cursor)
#   GOBLIN_REPOS     space-separated owner/repo slugs to enable (default: none)
set -euo pipefail

curl -fsS https://cursor.com/install | bash
sudo ln -sf "$HOME/.local/bin/cursor-agent" /usr/local/bin/cursor-agent

sudo rm -rf /opt/goblin
sudo git clone --depth 1 --quiet https://github.com/Wisammad/merge-goblin.git /opt/goblin
sudo chmod -R a+rX /opt/goblin

sudo tee /usr/local/bin/goblin >/dev/null <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
APP=/opt/goblin
CFG="${GOBLIN_HOME:-$HOME/.goblin}/config.json"
if [ ! -s "$CFG" ]; then
  # First run in this sandbox: goblin writes its own defaults (identity stays
  # empty, so the login comes from `gh api user`), then we point it at the repos.
  "$APP/bin/goblin" doctor >/dev/null 2>&1 || true
  repos="$(printf '%s\n' ${GOBLIN_REPOS:-} | jq -Rn '[inputs | select(length>0)
            | {slug: ., enabled: true, promptPath: "", login: ""}]')"
  tmp="$(mktemp)"
  jq --argjson repos "$repos" --arg p "${GOBLIN_PROVIDER:-cursor}" \
     '.provider = $p | .enabled = false | .repos = $repos | .notify.sound = false' \
     "$CFG" > "$tmp" && mv "$tmp" "$CFG"
fi
if [ -n "${OPENAI_API_KEY:-}" ] && ! codex login status >/dev/null 2>&1; then
  printenv OPENAI_API_KEY | codex login --with-api-key >/dev/null 2>&1 || true
fi
exec "$APP/bin/goblin" "$@"
SHIM
sudo chmod +x /usr/local/bin/goblin
