#!/usr/bin/env bash
# install-pod-claude.sh — Install Claude Code + MCPs (kb + notebooklm) on the
# pod, with EVERYTHING persisted to /workspace so a pod stop/start needs only
# `source /workspace/init-pod.sh` to restore the environment.
#
# Persistence model:
#   /workspace/.local-state    backs /root/.local        (claude, uv tools, nlm)
#   /workspace/.config-state   backs /root/.config       (gh auth, others)
#   /workspace/.claude-config  backs /root/.claude       (Claude Code auth + MCPs)
#   /workspace/.local-state/node-20/   Node 20 binary install (not via apt)
#   /workspace/.local-state/bin/       gh binary, claude, etc.
#   /workspace/.voxelo-kb/             kb-server clone
#   /workspace/.knowledge-base/.env    kb secrets
#   /workspace/init-pod.sh             run/source this on every fresh boot
#   /workspace/.profile-extras         PATH setup, sourced from /root/.bashrc

set -euo pipefail

WORKSPACE="/workspace"
REPO_DIR="${WORKSPACE}/lyra"
LOCAL_STATE="${WORKSPACE}/.local-state"
CONFIG_STATE="${WORKSPACE}/.config-state"
CLAUDE_CONFIG="${WORKSPACE}/.claude-config"
NODE_DIR="${LOCAL_STATE}/node-20"
NODE_VERSION="v20.18.1"
GH_VERSION="2.59.0"
KB_DIR="${WORKSPACE}/.voxelo-kb"
KB_ENV_DIR="${WORKSPACE}/.knowledge-base"

log()  { printf '\033[1;34m[install]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[install]\033[0m %s\n' "$*" >&2; }

# ─────────────────────────────────────────────────────────────
# Step 1: Set up persistent symlinks BEFORE any install
# ─────────────────────────────────────────────────────────────
mkdir -p "${LOCAL_STATE}/bin" "${CONFIG_STATE}" "${CLAUDE_CONFIG}"

relink() {
    local src="$1" dst="$2"
    if [[ -L "$dst" ]]; then return 0; fi
    if [[ -d "$dst" ]]; then
        log "Migrating existing $dst -> $src (preserving contents)"
        cp -rT "$dst" "$src" 2>/dev/null || true
        rm -rf "$dst"
    fi
    ln -sfn "$src" "$dst"
    log "Symlink: $dst -> $src"
}

relink "${LOCAL_STATE}"  /root/.local
relink "${CONFIG_STATE}" /root/.config
relink "${CLAUDE_CONFIG}" /root/.claude

# ─────────────────────────────────────────────────────────────
# Step 2: Install Node 20 to /workspace (persists across restart)
# ─────────────────────────────────────────────────────────────
if [[ ! -x "${NODE_DIR}/bin/node" ]]; then
    log "Installing Node ${NODE_VERSION} to ${NODE_DIR}"
    mkdir -p "${NODE_DIR}"
    curl -fsSL "https://nodejs.org/dist/${NODE_VERSION}/node-${NODE_VERSION}-linux-x64.tar.xz" \
      | tar -xJ --strip-components=1 -C "${NODE_DIR}"
fi
export PATH="${NODE_DIR}/bin:${LOCAL_STATE}/bin:${HOME}/.local/bin:${PATH}"
log "Node: $(node --version)  npm: $(npm --version)"

# ─────────────────────────────────────────────────────────────
# Step 3: Install gh CLI binary to /workspace (persists)
# ─────────────────────────────────────────────────────────────
if [[ ! -x "${LOCAL_STATE}/bin/gh" ]]; then
    log "Installing gh ${GH_VERSION} binary"
    curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_amd64.tar.gz" \
      | tar -xz -C /tmp
    mv "/tmp/gh_${GH_VERSION}_linux_amd64/bin/gh" "${LOCAL_STATE}/bin/gh"
    rm -rf "/tmp/gh_${GH_VERSION}_linux_amd64"
fi
log "gh: $(gh --version | head -1)"

# ─────────────────────────────────────────────────────────────
# Step 4: Claude Code (lands in /root/.local -> /workspace/.local-state)
# ─────────────────────────────────────────────────────────────
if ! command -v claude >/dev/null 2>&1; then
    log "Installing Claude Code (official native installer)"
    curl -fsSL https://claude.ai/install.sh | bash
fi
log "Claude Code: $(command -v claude || echo 'check PATH')"

# ─────────────────────────────────────────────────────────────
# Step 5: uv + notebooklm-mcp-cli (uv data also lands on volume via symlink)
# ─────────────────────────────────────────────────────────────
if ! command -v uv >/dev/null 2>&1; then
    log "Installing uv"
    curl -fsSL https://astral.sh/uv/install.sh | sh
fi
if ! command -v nlm >/dev/null 2>&1; then
    log "Installing notebooklm-mcp-cli via uv"
    uv tool install "git+https://github.com/jacob-bd/notebooklm-mcp-cli.git"
fi
log "notebooklm CLI: $(command -v nlm || echo 'check PATH')"

# ─────────────────────────────────────────────────────────────
# Step 6: kb-server (clone on volume; npm link via Node 20 in /workspace)
# ─────────────────────────────────────────────────────────────
if [[ ! -d "${KB_DIR}" ]]; then
    log "Installing kb-server (willynikes2/knowledge-base-server)"
    git clone https://github.com/willynikes2/knowledge-base-server.git "${KB_DIR}"
fi

# Ensure dependencies are installed against current Node
( cd "${KB_DIR}" && [[ -d node_modules ]] || npm install )
( cd "${KB_DIR}" && npm link )
log "kb-server CLI: $(command -v kb || echo 'check PATH after sourcing init-pod.sh')"

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

# ─────────────────────────────────────────────────────────────
# Step 7: CLAUDE.md + settings.local.json wired up in the lyra repo
# ─────────────────────────────────────────────────────────────
if [[ ! -e "${REPO_DIR}/CLAUDE.md" ]]; then
    ln -sfn .architect/pod-claude/CLAUDE.md "${REPO_DIR}/CLAUDE.md"
    log "CLAUDE.md linked from .architect/pod-claude/"
fi

mkdir -p "${REPO_DIR}/.claude"
if [[ ! -f "${REPO_DIR}/.claude/settings.local.json" ]]; then
    cp "${REPO_DIR}/.architect/pod-claude/settings.local.template.json" \
       "${REPO_DIR}/.claude/settings.local.json"
fi

# ─────────────────────────────────────────────────────────────
# Step 8: Clone continuity repos (private — needs gh auth on the pod)
# ─────────────────────────────────────────────────────────────
if ! gh auth status >/dev/null 2>&1; then
    warn "gh CLI not authenticated yet."
    warn "Run: gh auth login   (then re-run this script to clone the continuity repos)"
else
    gh auth setup-git 2>/dev/null || true
    for repo in agent-architect voxelo-brain; do
        if [[ ! -d "${WORKSPACE}/${repo}" ]]; then
            log "Cloning ${repo}"
            gh repo clone "voxeloai/${repo}" "${WORKSPACE}/${repo}" || warn "Clone of ${repo} failed; check team access"
        else
            ( cd "${WORKSPACE}/${repo}" && git pull --ff-only 2>/dev/null || true )
        fi
    done
fi

if command -v kb >/dev/null 2>&1 && [[ -d "${WORKSPACE}/voxelo-brain" ]]; then
    log "Ingesting voxelo-brain into kb-server"
    kb ingest "${WORKSPACE}/voxelo-brain" || warn "kb ingest failed; first-run UX may need interactive setup"
fi

# ─────────────────────────────────────────────────────────────
# Step 9: profile-extras + init-pod.sh for next-boot restoration
# ─────────────────────────────────────────────────────────────
cat > "${WORKSPACE}/.profile-extras" <<EOF
# Sourced from /root/.bashrc on each shell open.
# Adds /workspace persistent bin dirs to PATH so claude/gh/kb/nlm/node all work.
export PATH="${NODE_DIR}/bin:${LOCAL_STATE}/bin:\${HOME}/.local/bin:\${PATH}"
EOF
log "Wrote ${WORKSPACE}/.profile-extras"

cat > "${WORKSPACE}/init-pod.sh" <<'EOF'
# init-pod.sh — Source this on every fresh pod boot to restore the symlinks
# and PATH. The actual binaries live on the persistent volume; this just
# rebuilds the /root/.* symlinks and exports PATH for the current shell.
#
#   source /workspace/init-pod.sh
#
# Idempotent. ~1 second.

WORKSPACE="/workspace"
LOCAL_STATE="${WORKSPACE}/.local-state"
CONFIG_STATE="${WORKSPACE}/.config-state"
CLAUDE_CONFIG="${WORKSPACE}/.claude-config"

_relink() {
    local src="$1" dst="$2"
    if [[ -L "$dst" ]]; then return 0; fi
    if [[ -d "$dst" && ! -L "$dst" ]]; then
        cp -rT "$dst" "$src" 2>/dev/null || true
        rm -rf "$dst"
    fi
    ln -sfn "$src" "$dst"
}

_relink "${LOCAL_STATE}"  /root/.local
_relink "${CONFIG_STATE}" /root/.config
_relink "${CLAUDE_CONFIG}" /root/.claude

# Ensure /root/.bashrc sources our profile-extras for future shells
PROFILE_LINE='[ -f /workspace/.profile-extras ] && . /workspace/.profile-extras'
if ! grep -qF "$PROFILE_LINE" /root/.bashrc 2>/dev/null; then
    echo "$PROFILE_LINE" >> /root/.bashrc
fi

# Apply PATH to the current shell right now
[ -f "${WORKSPACE}/.profile-extras" ] && . "${WORKSPACE}/.profile-extras"

echo "[init-pod] Restored. claude / gh / kb / nlm / node available on PATH."
EOF
chmod +x "${WORKSPACE}/init-pod.sh"
log "Wrote ${WORKSPACE}/init-pod.sh"

# Make sure the source line is in /root/.bashrc for this pod too
PROFILE_LINE='[ -f /workspace/.profile-extras ] && . /workspace/.profile-extras'
if ! grep -qF "$PROFILE_LINE" /root/.bashrc 2>/dev/null; then
    echo "$PROFILE_LINE" >> /root/.bashrc
fi

# ─────────────────────────────────────────────────────────────
# Done
# ─────────────────────────────────────────────────────────────
log ""
log "DONE. Persisted to /workspace:"
log "  - claude   ($(command -v claude))"
log "  - gh       ($(command -v gh))"
log "  - kb       ($(command -v kb))"
log "  - nlm      ($(command -v nlm))"
log "  - node20   ($(command -v node))"
log ""
log "Manual steps now (one-time, also persisted):"
log "  1. claude /login                 # OAuth via browser code"
log "  2. gh auth login                 # if not done; for private clones"
log "  3. claude mcp add knowledge-base -- kb mcp"
log "     claude mcp add notebooklm-mcp -- nlm mcp"
log "  4. nlm login                     # optional, Google OAuth for NotebookLM"
log "  5. cd ${REPO_DIR} && claude      # start pod-Claude"
log ""
log "On EVERY future fresh pod boot, the only command needed is:"
log "  source /workspace/init-pod.sh"
log ""
log "First prompt to give pod-Claude:"
log "  Read .architect/pod-claude/CONTINUITY.md and follow it."
log ""
