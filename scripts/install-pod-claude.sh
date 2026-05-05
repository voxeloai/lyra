#!/usr/bin/env bash
# install-pod-claude.sh — Install Claude Code + MCPs (kb + notebooklm) on the
# pod, with config persisted to the volume so it survives stop/start. Run on
# the pod once after cycle 1+2+3 are done. Idempotent.
#
# Sets up:
#   - Claude Code (CLI)
#   - Persistent config at /workspace/.claude-config -> ~/.claude (junction)
#   - Continuity repos cloned into /workspace/{agent-architect, voxelo-brain}
#   - kb-server installed and pointed at /workspace/voxelo-brain
#   - notebooklm-mcp-cli installed via uv
#   - MCP entries staged for `claude mcp add`
#   - CLAUDE.md symlinked from .architect/pod-claude/CLAUDE.md to repo root
#   - .claude/settings.local.json copied from template
#
# What this script does NOT do (interactive, run yourself):
#   - claude /login              (OAuth via browser; URL will be printed)
#   - claude mcp add ...         (register the MCPs after auth)
#   - hf auth login              (if you want hf CLI auth on the pod too)

set -euo pipefail

WORKSPACE="/workspace"
REPO_DIR="${WORKSPACE}/lyra"
CLAUDE_CONFIG="${WORKSPACE}/.claude-config"
KB_DIR="${WORKSPACE}/.voxelo-kb"
KB_ENV_DIR="${WORKSPACE}/.knowledge-base"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }

# ─────────────────────────────────────────────────────────────
# 1. Claude Code
# ─────────────────────────────────────────────────────────────
if ! command -v claude >/dev/null 2>&1; then
    log "Installing Claude Code (official native installer from docs.claude.com)"
    # Official URL per https://code.claude.com/docs/en/setup (verified 2026-05).
    # Native install lands at ~/.local/bin/claude, auto-updates in background.
    if curl -fsSL https://claude.ai/install.sh | bash; then
        true
    else
        log "Native installer failed; falling back to npm"
        if ! command -v npm >/dev/null 2>&1; then
            apt-get install -y nodejs npm
        fi
        npm install -g @anthropic-ai/claude-code
    fi
    export PATH="$HOME/.local/bin:$HOME/.npm-global/bin:/usr/local/bin:$PATH"
fi
log "Claude Code: $(command -v claude || echo 'not on PATH; try: source ~/.bashrc then re-run')"

# ─────────────────────────────────────────────────────────────
# 2. Persist Claude config to the volume so OAuth + history
#    survive pod stop/start
# ─────────────────────────────────────────────────────────────
mkdir -p "${CLAUDE_CONFIG}"
if [[ -d "/root/.claude" && ! -L "/root/.claude" ]]; then
    log "Migrating existing /root/.claude -> ${CLAUDE_CONFIG}"
    cp -rT /root/.claude "${CLAUDE_CONFIG}"
    rm -rf /root/.claude
fi
if [[ ! -L "/root/.claude" ]]; then
    ln -sfn "${CLAUDE_CONFIG}" /root/.claude
fi
log "Claude config persisted: /root/.claude -> ${CLAUDE_CONFIG}"

# ─────────────────────────────────────────────────────────────
# 3. CLAUDE.md + settings.local.json wired up in the lyra repo
# ─────────────────────────────────────────────────────────────
if [[ ! -e "${REPO_DIR}/CLAUDE.md" ]]; then
    ln -sfn .architect/pod-claude/CLAUDE.md "${REPO_DIR}/CLAUDE.md"
    log "CLAUDE.md linked from .architect/pod-claude/"
fi

mkdir -p "${REPO_DIR}/.claude"
if [[ ! -f "${REPO_DIR}/.claude/settings.local.json" ]]; then
    cp "${REPO_DIR}/.architect/pod-claude/settings.local.template.json" \
       "${REPO_DIR}/.claude/settings.local.json"
    log "settings.local.json dropped from template"
fi

# ─────────────────────────────────────────────────────────────
# 4. Clone continuity repos (private — needs gh auth on the pod)
# ─────────────────────────────────────────────────────────────
# Install gh CLI on the pod if missing
if ! command -v gh >/dev/null 2>&1; then
    log "Installing GitHub CLI (gh)"
    type -p curl >/dev/null || apt-get install -y curl
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
    apt-get update -qq
    apt-get install -y gh
fi

# Check if gh is authed; if not, skip private-repo clones gracefully
if ! gh auth status >/dev/null 2>&1; then
    warn "gh CLI is installed but not authenticated."
    warn "To clone the continuity repos (private), run on the pod:"
    warn "    gh auth login          # pick HTTPS + browser; paste device code"
    warn "    bash $0                # re-run this script to finish"
    warn "Continuing with the rest of the install — the pod will still work for"
    warn "Lyra-2 inference, just without /workspace/agent-architect or /workspace/voxelo-brain."
else
    # Use gh's git credential helper so HTTPS clones use the OAuth token
    gh auth setup-git 2>/dev/null || true
    for repo in agent-architect voxelo-brain; do
        if [[ ! -d "${WORKSPACE}/${repo}" ]]; then
            log "Cloning ${repo} (via gh)"
            gh repo clone "voxeloai/${repo}" "${WORKSPACE}/${repo}" || \
                warn "Failed to clone ${repo}; check team membership or run 'gh auth login --scopes repo'"
        else
            log "Updating ${repo}"
            ( cd "${WORKSPACE}/${repo}" && git pull --ff-only 2>/dev/null || true )
        fi
    done
fi

# ─────────────────────────────────────────────────────────────
# 5. Install kb-server (knowledge-base) and point at voxelo-brain
# ─────────────────────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1; then
    apt-get install -y nodejs npm
fi

if [[ ! -d "${KB_DIR}" ]]; then
    log "Installing kb-server (willynikes2/knowledge-base-server)"
    git clone https://github.com/willynikes2/knowledge-base-server.git "${KB_DIR}"
    ( cd "${KB_DIR}" && npm install && npm link )
fi
log "kb-server CLI: $(command -v kb || echo 'check PATH')"

# kb env (random secrets, never echo)
mkdir -p "${KB_ENV_DIR}"
if [[ ! -f "${KB_ENV_DIR}/.env" ]]; then
    cat > "${KB_ENV_DIR}/.env" <<EOF
KB_VAULT_PATH=${WORKSPACE}/voxelo-brain
KB_DASHBOARD_PASSWORD=$(openssl rand -hex 16)
KB_API_KEY=$(openssl rand -hex 24)
EOF
    chmod 600 "${KB_ENV_DIR}/.env"
    log "kb .env generated at ${KB_ENV_DIR}/.env (chmod 600)"
fi

# Initial ingest of the voxelo-brain into kb-server (only if the brain was cloned)
if command -v kb >/dev/null 2>&1 && [[ -d "${WORKSPACE}/voxelo-brain" ]]; then
    log "Ingesting voxelo-brain into kb-server"
    kb ingest "${WORKSPACE}/voxelo-brain" || warn "kb ingest failed (may be fine if first-run UX needs interactive setup)"
elif [[ ! -d "${WORKSPACE}/voxelo-brain" ]]; then
    log "Skipping kb ingest: /workspace/voxelo-brain not yet cloned (run gh auth login + re-run script)"
fi

# ─────────────────────────────────────────────────────────────
# 6. Install notebooklm-mcp-cli via uv
# ─────────────────────────────────────────────────────────────
if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv"
    curl -fsSL https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
if ! command -v nlm >/dev/null 2>&1; then
    log "Installing notebooklm-mcp-cli via uv"
    uv tool install "git+https://github.com/jacob-bd/notebooklm-mcp-cli.git"
fi
log "notebooklm CLI: $(command -v nlm || echo 'check PATH')"

# ─────────────────────────────────────────────────────────────
# 7. Print MCP registration commands (run yourself after auth)
# ─────────────────────────────────────────────────────────────
log ""
log "DONE with the automated parts. Manual steps now:"
log ""
log "1. Authenticate Claude Code (OAuth via browser):"
log "     cd ${REPO_DIR} && claude /login"
log "   (or set ANTHROPIC_API_KEY in /workspace/.claude-config/env if you prefer API key)"
log ""
log "2. Register the MCPs:"
log "     claude mcp add knowledge-base -- kb mcp"
log "     claude mcp add notebooklm-mcp -- nlm mcp"
log "   Then verify with: claude mcp list"
log ""
log "3. (Optional) Authenticate notebooklm-mcp to your Google account:"
log "     nlm login"
log ""
log "4. Start pod-Claude (CLAUDE.md and settings auto-load):"
log "     cd ${REPO_DIR} && claude"
log ""
log "5. First prompt to give it:"
log "     'Read .architect/pod-claude/CONTINUITY.md and follow it.'"
log ""
