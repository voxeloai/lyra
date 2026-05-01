#!/usr/bin/env bash
# deploy.sh — create RunPod network volume + H100 pod for Lyra-2.
#
# Reads secrets from caller's environment. Never echoes them.
# Required env vars (set in YOUR shell, not in this file or in chat):
#   RUNPOD_API_KEY  authenticates runpodctl (or save once via `runpodctl doctor`)
#   HF_TOKEN        passed to the pod as an env var; needed for HF model downloads
#
# Optional overrides (env vars):
#   POD_NAME        default: lyra-2
#   VOLUME_NAME     default: lyra-workspace
#   VOLUME_SIZE_GB  default: 300
#   GPU_ID          default: "NVIDIA H100 80GB HBM3"   (SXM variant)
#   GPU_COUNT       default: 1
#   POD_IMAGE       default: runpod/pytorch:2.7.1-py3.10-cuda12.8.0-devel-ubuntu22.04
#   CONTAINER_DISK_GB  default: 50
#   DATA_CENTER_ID  default: auto (script picks the first DC with H100 stock)
#   CLOUD_TYPE      default: SECURE
#
# After successful create, prints pod id, status, and SSH command. Then the
# pod-level work (clone repo, run bootstrap.sh, run cycle 1) is whatever
# .architect/POD-DEPLOY.md describes.

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Defaults
# ─────────────────────────────────────────────────────────────
POD_NAME="${POD_NAME:-lyra-2}"
VOLUME_NAME="${VOLUME_NAME:-lyra-workspace}"
VOLUME_SIZE_GB="${VOLUME_SIZE_GB:-300}"
GPU_ID="${GPU_ID:-NVIDIA H100 80GB HBM3}"
GPU_COUNT="${GPU_COUNT:-1}"
POD_IMAGE="${POD_IMAGE:-runpod/pytorch:2.7.1-py3.10-cuda12.8.0-devel-ubuntu22.04}"
CONTAINER_DISK_GB="${CONTAINER_DISK_GB:-50}"
DATA_CENTER_ID="${DATA_CENTER_ID:-auto}"
CLOUD_TYPE="${CLOUD_TYPE:-SECURE}"

log()  { printf '\033[1;34m[deploy]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[deploy]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[deploy]\033[0m %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# Resolve binaries — Git Bash on Windows often doesn't inherit the same
# PATH PowerShell sees, so probe common locations after `command -v` fails.
# ─────────────────────────────────────────────────────────────
resolve_bin() {
    local name="$1"; shift
    local found=""

    # 1. Standard PATH lookup
    if command -v "$name" >/dev/null 2>&1; then
        found="$(command -v "$name")"
    fi

    # 2. Probe explicit candidate paths
    if [[ -z "$found" ]]; then
        for candidate in "$@"; do
            if [[ -x "$candidate" ]]; then
                found="$candidate"
                break
            fi
        done
    fi

    # 3. Windows-native fallback: where.exe finds binaries on the Windows PATH
    #    regardless of which bash flavour we're in (Git Bash / MSYS2 / WSL).
    #    Convert "C:\foo\bar.exe" → "/c/foo/bar.exe" so bash can execute it.
    if [[ -z "$found" ]] && command -v where.exe >/dev/null 2>&1; then
        local win_path
        win_path="$(where.exe "$name" 2>/dev/null | head -1 | tr -d '\r')"
        if [[ -n "$win_path" ]]; then
            # Prefer cygpath if available — it handles edge cases properly.
            if command -v cygpath >/dev/null 2>&1; then
                found="$(cygpath -u "$win_path" 2>/dev/null || true)"
            fi
            # Manual fallback if cygpath isn't there or returned nothing.
            if [[ -z "$found" || ! -x "$found" ]]; then
                local p="${win_path//\\//}"
                if [[ "$p" =~ ^([A-Za-z]):(.*)$ ]]; then
                    local drive
                    drive=$(echo "${BASH_REMATCH[1]}" | tr 'A-Z' 'a-z')
                    found="/${drive}${BASH_REMATCH[2]}"
                else
                    found="$p"
                fi
            fi
        fi
    fi

    printf '%s' "$found"
}

_HOME="${HOME:-}"
RPCTL=$(resolve_bin runpodctl \
    "${_HOME}/.local/bin/runpodctl.exe" \
    "${_HOME}/.local/bin/runpodctl" \
    "/c/Users/${USERNAME:-}/.local/bin/runpodctl.exe")
[[ -n "${RPCTL}" ]] || fail "runpodctl not on PATH and not at \$HOME/.local/bin or via where.exe. Install or extend PATH."

JQ=$(resolve_bin jq \
    "${_HOME}/.local/bin/jq.exe" \
    "/c/Program Files/jq/jq.exe" \
    "/c/ProgramData/chocolatey/bin/jq.exe")
[[ -n "${JQ}" ]] || fail "jq not on PATH. Install: winget install jqlang.jq  (then open a fresh shell)"

log "Using runpodctl: ${RPCTL}"
log "Using jq:        ${JQ}"

# ─────────────────────────────────────────────────────────────
# Auth + secret pre-flight
# ─────────────────────────────────────────────────────────────
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
    USER_OUT=$("${RPCTL}" user 2>&1) || true
    if echo "${USER_OUT}" | grep -q '"error"'; then
        warn "runpodctl user returned an error:"
        printf '%s\n' "${USER_OUT}" | sed 's/^/  | /'
        fail "Auth check failed. Run: runpodctl doctor (paste your API key when prompted), then re-run this script."
    fi
    if ! echo "${USER_OUT}" | grep -qE '"(id|email|userId|user_id)"'; then
        warn "runpodctl user did not return recognisable account JSON. Output was:"
        printf '%s\n' "${USER_OUT}" | sed 's/^/  | /'
        fail "Auth check failed. If runpodctl user works for you directly, paste its output and we'll widen the regex."
    fi
fi

if [[ -z "${HF_TOKEN:-}" ]]; then
    fail "HF_TOKEN not set. export HF_TOKEN=hf_... in your shell, then re-run."
fi

log "Account check"
"${RPCTL}" user 2>&1 | "${JQ}" -r '"  user: \(.email // .id // "unknown")  balance: \(.spendLimit // "?" )"' || true

# ─────────────────────────────────────────────────────────────
# Pick a data center with H100 stock
# ─────────────────────────────────────────────────────────────
if [[ "${DATA_CENTER_ID}" = "auto" ]]; then
    log "Discovering datacenter with stock for: ${GPU_ID}"
    DC_CANDIDATES=$("${RPCTL}" gpu list -o json 2>/dev/null \
        | "${JQ}" -r --arg gpu "$GPU_ID" \
            '[.[] | select(.id == $gpu) | .dataCenters[]?.id] | unique | .[]' \
        | head -10)
    if [[ -z "${DC_CANDIDATES}" ]]; then
        warn "Could not auto-discover a DC for '${GPU_ID}'. Falling back to common candidates."
        DC_CANDIDATES=$'EU-RO-1\nUS-KS-2\nEU-CZ-1\nUS-CA-2'
    fi
    log "Candidate DCs: $(echo "${DC_CANDIDATES}" | tr '\n' ' ')"
    DATA_CENTER_ID=$(echo "${DC_CANDIDATES}" | head -1)
fi
log "Using DATA_CENTER_ID=${DATA_CENTER_ID}"

# ─────────────────────────────────────────────────────────────
# Network volume — create if missing, reuse if present
# ─────────────────────────────────────────────────────────────
log "Looking for existing volume named '${VOLUME_NAME}'"
EXISTING_VOLUME=$("${RPCTL}" network-volume list -o json 2>/dev/null \
    | "${JQ}" -r --arg name "$VOLUME_NAME" \
        '[.[] | select(.name == $name)] | first.id // empty')

if [[ -n "${EXISTING_VOLUME}" ]]; then
    VOLUME_ID="${EXISTING_VOLUME}"
    log "Reusing existing volume: ${VOLUME_ID}"
else
    log "Creating volume: name=${VOLUME_NAME} size=${VOLUME_SIZE_GB}GB dc=${DATA_CENTER_ID}"
    CREATE_OUT=$("${RPCTL}" network-volume create \
        --name "${VOLUME_NAME}" \
        --size "${VOLUME_SIZE_GB}" \
        --data-center-id "${DATA_CENTER_ID}" \
        -o json 2>&1)
    VOLUME_ID=$(echo "${CREATE_OUT}" | "${JQ}" -r '.id // empty')
    [[ -n "${VOLUME_ID}" ]] || fail "Volume create failed: ${CREATE_OUT}"
    log "Created volume: ${VOLUME_ID}"
fi

# ─────────────────────────────────────────────────────────────
# Pod — refuse to create dup
# ─────────────────────────────────────────────────────────────
EXISTING_POD=$("${RPCTL}" pod list -o json 2>/dev/null \
    | "${JQ}" -r --arg name "$POD_NAME" \
        '[.[] | select(.name == $name)] | first.id // empty')
if [[ -n "${EXISTING_POD}" ]]; then
    warn "Pod named '${POD_NAME}' already exists (id=${EXISTING_POD})."
    warn "Refusing to create a duplicate. Stop/rename it, or set POD_NAME=other."
    exit 0
fi

# Build the env JSON with jq so escaping is correct. The HF_TOKEN value
# is never echoed; we only assert its presence above.
ENV_JSON=$("${JQ}" -nc --arg t "$HF_TOKEN" \
    '{HF_TOKEN: $t, PYTORCH_CUDA_ALLOC_CONF: "expandable_segments:True"}')

# ─────────────────────────────────────────────────────────────
# Create the pod
# ─────────────────────────────────────────────────────────────
log "Creating pod: name=${POD_NAME} gpu=${GPU_ID} x${GPU_COUNT} dc=${DATA_CENTER_ID}"
log "  image=${POD_IMAGE}"
log "  volume=${VOLUME_ID} mount=/workspace size=${VOLUME_SIZE_GB}GB"

POD_OUT=$("${RPCTL}" pod create \
    --name "${POD_NAME}" \
    --cloud-type "${CLOUD_TYPE}" \
    --gpu-id "${GPU_ID}" \
    --gpu-count "${GPU_COUNT}" \
    --container-disk-in-gb "${CONTAINER_DISK_GB}" \
    --data-center-ids "${DATA_CENTER_ID}" \
    --network-volume-id "${VOLUME_ID}" \
    --volume-mount-path "/workspace" \
    --image "${POD_IMAGE}" \
    --env "${ENV_JSON}" \
    --ssh \
    --ports "22/tcp" \
    -o json 2>&1)

POD_ID=$(echo "${POD_OUT}" | "${JQ}" -r '.id // empty')
[[ -n "${POD_ID}" ]] || fail "Pod create failed: ${POD_OUT}"

log "Pod created: ${POD_ID}"
log "Waiting for pod to enter RUNNING status..."

for _ in $(seq 1 18); do
    STATUS=$("${RPCTL}" pod get "${POD_ID}" -o json 2>/dev/null | "${JQ}" -r '.desiredStatus // "?"')
    if [[ "${STATUS}" = "RUNNING" ]]; then break; fi
    sleep 10
done

# ─────────────────────────────────────────────────────────────
# Print connection info
# ─────────────────────────────────────────────────────────────
POD_INFO=$("${RPCTL}" pod get "${POD_ID}" -o json 2>/dev/null)
PUBLIC_IP=$(echo "${POD_INFO}"   | "${JQ}" -r '.runtime.ports[]? | select(.privatePort==22) | .ip         // empty' | head -1)
PUBLIC_PORT=$(echo "${POD_INFO}" | "${JQ}" -r '.runtime.ports[]? | select(.privatePort==22) | .publicPort // empty' | head -1)

cat <<EOF

[deploy] DONE
  pod id:     ${POD_ID}
  status:     $(echo "${POD_INFO}" | "${JQ}" -r '.desiredStatus // "?"')
  volume id:  ${VOLUME_ID}

SSH:
  ssh root@${PUBLIC_IP:-<see-runpod-console>} -p ${PUBLIC_PORT:-<see-runpod-console>} -i ~/.ssh/id_runpod

Next steps (on the pod):
  cd /workspace
  git clone https://github.com/voxeloai/lyra.git
  cd lyra
  git checkout voxelo/main
  bash scripts/bootstrap.sh
  source /workspace/activate.sh
  # then start Claude Code on the pod and point it at .architect/task.md
EOF
