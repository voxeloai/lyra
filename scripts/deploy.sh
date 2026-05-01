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
# Pre-flight checks
# ─────────────────────────────────────────────────────────────
command -v runpodctl >/dev/null 2>&1 || fail "runpodctl not on PATH"
command -v jq >/dev/null 2>&1 || fail "jq not on PATH (needed for parsing runpodctl output)"

# Auth: env var OR cached config
if [[ -z "${RUNPOD_API_KEY:-}" ]]; then
    if ! runpodctl user 2>/dev/null | grep -q '"id"'; then
        fail "RUNPOD_API_KEY not set and no cached config. Run: runpodctl doctor"
    fi
fi

# HF_TOKEN required for the pod to download nvidia/Lyra-2.0
if [[ -z "${HF_TOKEN:-}" ]]; then
    fail "HF_TOKEN not set. export HF_TOKEN=hf_... in your shell, then re-run."
fi

log "Account check"
runpodctl user 2>&1 | jq -r '"  user: \(.email // .id // "unknown")  balance: \(.spendLimit // "?" )"'

# ─────────────────────────────────────────────────────────────
# Pick a data center with H100 stock
# ─────────────────────────────────────────────────────────────
if [[ "${DATA_CENTER_ID}" = "auto" ]]; then
    log "Discovering datacenter with H100 SXM 80GB stock"
    # GPU availability is per-DC; runpodctl gpu list shows it.
    # Fallback: try a sensible ordered list.
    DC_CANDIDATES=$(runpodctl gpu list -o json 2>/dev/null \
        | jq -r --arg gpu "$GPU_ID" \
            '[.[] | select(.id == $gpu) | .dataCenters[]?.id] | unique | .[]' \
        | head -10)
    if [[ -z "${DC_CANDIDATES}" ]]; then
        warn "Could not auto-discover a DC. Falling back to common candidates."
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
EXISTING_VOLUME=$(runpodctl network-volume list -o json 2>/dev/null \
    | jq -r --arg name "$VOLUME_NAME" \
        '[.[] | select(.name == $name)] | first.id // empty')

if [[ -n "${EXISTING_VOLUME}" ]]; then
    VOLUME_ID="${EXISTING_VOLUME}"
    log "Reusing existing volume: ${VOLUME_ID}"
else
    log "Creating volume: name=${VOLUME_NAME} size=${VOLUME_SIZE_GB}GB dc=${DATA_CENTER_ID}"
    CREATE_OUT=$(runpodctl network-volume create \
        --name "${VOLUME_NAME}" \
        --size "${VOLUME_SIZE_GB}" \
        --data-center-id "${DATA_CENTER_ID}" \
        -o json 2>&1)
    VOLUME_ID=$(echo "${CREATE_OUT}" | jq -r '.id // empty')
    [[ -n "${VOLUME_ID}" ]] || fail "Volume create failed: ${CREATE_OUT}"
    log "Created volume: ${VOLUME_ID}"
fi

# ─────────────────────────────────────────────────────────────
# Pod — refuse to create dup; report if pod already exists by name
# ─────────────────────────────────────────────────────────────
EXISTING_POD=$(runpodctl pod list -o json 2>/dev/null \
    | jq -r --arg name "$POD_NAME" \
        '[.[] | select(.name == $name)] | first | "\(.id // empty) \(.desiredStatus // "?")"')
if [[ -n "${EXISTING_POD% *}" ]]; then
    warn "Pod named '${POD_NAME}' already exists: ${EXISTING_POD}"
    warn "Refusing to create a duplicate. Stop or rename that pod, or set POD_NAME=other."
    exit 0
fi

# ─────────────────────────────────────────────────────────────
# Build the env JSON without exposing the value to logs
# ─────────────────────────────────────────────────────────────
# jq builds the JSON so quoting/escaping is correct. HF_TOKEN value never
# echoed; only its presence is asserted by the pre-flight check.
ENV_JSON=$(jq -nc --arg t "$HF_TOKEN" '{HF_TOKEN: $t, PYTORCH_CUDA_ALLOC_CONF: "expandable_segments:True"}')

# ─────────────────────────────────────────────────────────────
# Create the pod
# ─────────────────────────────────────────────────────────────
log "Creating pod: name=${POD_NAME} gpu=${GPU_ID} x${GPU_COUNT} dc=${DATA_CENTER_ID}"
log "  image=${POD_IMAGE}"
log "  volume=${VOLUME_ID} mount=/workspace size=${VOLUME_SIZE_GB}GB"

POD_OUT=$(runpodctl pod create \
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

POD_ID=$(echo "${POD_OUT}" | jq -r '.id // empty')
[[ -n "${POD_ID}" ]] || fail "Pod create failed: ${POD_OUT}"

log "Pod created: ${POD_ID}"
log "Waiting for pod to enter RUNNING status..."

# Poll until running (or timeout after ~3 min)
for _ in $(seq 1 18); do
    STATUS=$(runpodctl pod get "${POD_ID}" -o json 2>/dev/null | jq -r '.desiredStatus // "?"')
    if [[ "${STATUS}" = "RUNNING" ]]; then break; fi
    sleep 10
done

# ─────────────────────────────────────────────────────────────
# Print connection info
# ─────────────────────────────────────────────────────────────
POD_INFO=$(runpodctl pod get "${POD_ID}" -o json 2>/dev/null)
SSH_HOST=$(echo "${POD_INFO}" | jq -r '.machine.podHostId // .runtime.gpus[0]?.id // empty')
PUBLIC_IP=$(echo "${POD_INFO}" | jq -r '.runtime.ports[]? | select(.privatePort==22) | .ip // empty' | head -1)
PUBLIC_PORT=$(echo "${POD_INFO}" | jq -r '.runtime.ports[]? | select(.privatePort==22) | .publicPort // empty' | head -1)

cat <<EOF

[deploy] DONE
  pod id:     ${POD_ID}
  status:     $(echo "${POD_INFO}" | jq -r '.desiredStatus // "?"')
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
