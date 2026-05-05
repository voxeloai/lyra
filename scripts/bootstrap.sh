#!/usr/bin/env bash
# bootstrap.sh — Lyra-2 first-boot install + idempotent re-run after stop/start.
# Mirrors Lyra-2/INSTALL.md, sentinel-gated so re-runs after a stop/start are no-ops.
#
# Phase flags (env vars, default values shown):
#   LYRA_BUILD_KERNELS=0   skip Flash Attention + VIPE + DA3 builds (cycle 1)
#   LYRA_DOWNLOAD_WEIGHTS=0  skip HuggingFace weights download (cycle 1)
# Set both to 1 for full install (cycle 2+).
#
# Required env (set in RunPod pod env-var config, NEVER in this script):
#   HF_TOKEN              for huggingface-cli auth (gated nvidia/Lyra-2.0)
#
# Refined per-cycle as pod-Claude debugs. status: DRAFT until cycle 3 locks RECIPE.md.

set -euo pipefail

# ─────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────
ENV_NAME="lyra2"
PYTHON_VERSION="3.10"
GCC_VERSION="13.3.0"
HF_REPO_ID="nvidia/Lyra-2.0"
HF_INCLUDE_PATTERN="checkpoints/*"
BUILD_VERSION="v1"

LYRA_BUILD_KERNELS="${LYRA_BUILD_KERNELS:-0}"
LYRA_DOWNLOAD_WEIGHTS="${LYRA_DOWNLOAD_WEIGHTS:-0}"

# Paths
WORKSPACE="/workspace"
REPO_DIR="${WORKSPACE}/lyra"
CONDA_DIR="${WORKSPACE}/miniconda3"
ENV_DIR="${WORKSPACE}/envs/${ENV_NAME}"
WEIGHTS_DIR="${WORKSPACE}/weights"
HF_CACHE_DIR="${WORKSPACE}/hf-cache"
OUTPUTS_DIR="${WORKSPACE}/outputs"
BUILD_SENTINEL="${WORKSPACE}/.build-complete-${BUILD_VERSION}"
WEIGHTS_SENTINEL="${WORKSPACE}/.weights-complete"
ACTIVATE_SCRIPT="${WORKSPACE}/activate.sh"

mkdir -p "${WORKSPACE}/envs" "${WEIGHTS_DIR}" "${HF_CACHE_DIR}" "${OUTPUTS_DIR}"

log()  { printf '\033[1;34m[bootstrap]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[bootstrap]\033[0m %s\n' "$*" >&2; }
fail() { printf '\033[1;31m[bootstrap]\033[0m %s\n' "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# Step 0: ephemeral system packages (re-run on every pod start)
# ─────────────────────────────────────────────────────────────
log "Step 0: system packages (ephemeral)"
apt-get update -qq
apt-get install -y -qq git curl ca-certificates build-essential

# ─────────────────────────────────────────────────────────────
# Step 1: Miniconda (once, on volume)
# ─────────────────────────────────────────────────────────────
if [[ ! -x "${CONDA_DIR}/bin/conda" ]]; then
    log "Step 1: installing Miniconda → ${CONDA_DIR}"
    curl -fsSL https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh
    bash /tmp/miniconda.sh -b -p "${CONDA_DIR}"
    rm /tmp/miniconda.sh
else
    log "Step 1: Miniconda present, skipping"
fi
# shellcheck source=/dev/null
source "${CONDA_DIR}/etc/profile.d/conda.sh"

# Accept Anaconda channel ToS up-front — required since 2024 for
# repo.anaconda.com/pkgs/main and /pkgs/r. Idempotent; safe to re-run.
log "Accepting conda channel ToS (idempotent)"
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>/dev/null || true
conda tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r    2>/dev/null || true

# Install + use libmamba solver. The classic solver can't resolve nvidia's
# cuda channel alongside conda-forge gcc=13.3.0. libmamba handles it cleanly.
# Idempotent — won't reinstall if already configured.
if ! conda config --show solver 2>/dev/null | grep -q libmamba; then
    log "Installing libmamba solver in base env"
    conda install -n base -y -c conda-forge conda-libmamba-solver 2>&1 | tail -3
    conda config --set solver libmamba
fi

# ─────────────────────────────────────────────────────────────
# Step 2: conda env (once, on volume)
# ─────────────────────────────────────────────────────────────
if [[ ! -d "${ENV_DIR}" ]]; then
    log "Step 2: creating conda env at ${ENV_DIR}"
    conda create -y -p "${ENV_DIR}" \
        "python=${PYTHON_VERSION}" pip cmake ninja libgl ffmpeg packaging \
        -c conda-forge
else
    log "Step 2: conda env present, skipping create"
fi
conda activate "${ENV_DIR}"

# Step 2a: gcc / gxx / eigen / zlib via conda (per INSTALL.md)
if ! conda list -p "${ENV_DIR}" gcc 2>/dev/null | grep -q "^gcc "; then
    log "Step 2a: installing gcc-${GCC_VERSION} + gxx + eigen + zlib via conda-forge"
    CONDA_BACKUP_CXX="" conda install -y -p "${ENV_DIR}" \
        "gcc=${GCC_VERSION}" "gxx=${GCC_VERSION}" eigen zlib \
        -c conda-forge
else
    log "Step 2a: gcc/gxx/eigen/zlib present, skipping"
fi

# ─────────────────────────────────────────────────────────────
# Step 3: CUDA — prefer the base image's system install if present.
#
# RunPod's pytorch base images ship a CUDA-devel install at /usr/local/cuda
# (with nvcc + headers + libs). That's exactly what Lyra-2's build needs.
# Installing CUDA via conda is only needed if there's no system install,
# AND nvidia/label/cuda-12.8.0 has no Linux package as of 2026-05; only
# 12.8.1+ does. Detect and use system path when available.
# ─────────────────────────────────────────────────────────────
SYSTEM_CUDA="/usr/local/cuda"
if [[ -d "${SYSTEM_CUDA}" && -x "${SYSTEM_CUDA}/bin/nvcc" ]]; then
    NVCC_VERSION=$("${SYSTEM_CUDA}/bin/nvcc" --version 2>/dev/null | grep -oP 'release \K[0-9.]+' || echo "?")
    log "Step 3: using system CUDA at ${SYSTEM_CUDA}  (nvcc ${NVCC_VERSION})"
    export CUDA_HOME="${SYSTEM_CUDA}"
else
    if ! conda list -p "${ENV_DIR}" cuda 2>/dev/null | grep -q "^cuda "; then
        log "Step 3: no system CUDA found; installing via conda (nvidia/label/cuda-12.8.1)"
        conda install -y -p "${ENV_DIR}" cuda -c nvidia/label/cuda-12.8.1
    else
        log "Step 3: CUDA toolkit present in conda env, skipping"
    fi
    export CUDA_HOME="${ENV_DIR}"
fi
log "  CUDA_HOME=${CUDA_HOME}"

# ─────────────────────────────────────────────────────────────
# Step 3a: ensure git submodules are populated (idempotent)
# Lyra-2's vipe and depth_anything_3 are submodules under
# lyra_2/_src/inference/. Without this, step 7's pip -e install fails
# with 'neither setup.py nor pyproject.toml found'.
# ─────────────────────────────────────────────────────────────
log "Step 3a: ensuring submodules are initialised"
( cd "${REPO_DIR}" && git submodule update --init --recursive )

# ─────────────────────────────────────────────────────────────
# Step 4: PyTorch
# ─────────────────────────────────────────────────────────────
if ! python -c "import torch; assert torch.__version__.startswith('2.7.1')" 2>/dev/null; then
    log "Step 4: installing PyTorch 2.7.1 (cu128)"
    pip install --quiet \
        torch==2.7.1 torchvision==0.22.1 \
        --extra-index-url https://download.pytorch.org/whl/cu128
else
    log "Step 4: PyTorch 2.7.1 present, skipping"
fi

# Step 4a: build env vars (always set)
SITE="${ENV_DIR}/lib/python${PYTHON_VERSION}/site-packages"
export CPATH="${CUDA_HOME}/include:${SITE}/nvidia/cudnn/include:${SITE}/nvidia/nccl/include${CPATH:+:${CPATH}}"
export LD_LIBRARY_PATH="${ENV_DIR}/lib:${SITE}/torch/lib:${SITE}/nvidia/cuda_runtime/lib:${SITE}/nvidia/cudnn/lib:${CUDA_HOME}/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
export CC="${ENV_DIR}/bin/x86_64-conda-linux-gnu-gcc"
export CXX="${ENV_DIR}/bin/x86_64-conda-linux-gnu-g++"

# ─────────────────────────────────────────────────────────────
# Step 5: Python deps (idempotent — pip handles already-installed)
# ─────────────────────────────────────────────────────────────
log "Step 5: installing Python deps"
pip install --no-deps -r "${REPO_DIR}/Lyra-2/requirements.txt"
pip install "git+https://github.com/microsoft/MoGe.git"
pip install --no-build-isolation "transformer_engine[pytorch]"

# Symlink cudart → cuda_runtime (idempotent)
ln -sf "${SITE}/nvidia/cuda_runtime" "${SITE}/nvidia/cudart"

# ─────────────────────────────────────────────────────────────
# Step 6: Flash Attention + custom CUDA extensions (slow; gated)
# ─────────────────────────────────────────────────────────────
if [[ "${LYRA_BUILD_KERNELS}" = "1" ]]; then
    if [[ ! -f "${BUILD_SENTINEL}" ]]; then
        log "Step 6: building Flash Attention 2.6.3 (this is the slow part)"
        MAX_JOBS=16 pip install --no-build-isolation --no-binary :all: flash-attn==2.6.3

        log "Step 7: building VIPE"
        USE_SYSTEM_EIGEN=1 pip install --no-build-isolation -e "${REPO_DIR}/Lyra-2/lyra_2/_src/inference/vipe"

        log "Step 7: building Depth Anything 3 [gs]"
        pip install --no-build-isolation -e "${REPO_DIR}/Lyra-2/lyra_2/_src/inference/depth_anything_3[gs]"

        touch "${BUILD_SENTINEL}"
        log "kernel build complete; sentinel: ${BUILD_SENTINEL}"
    else
        log "Step 6/7: build sentinel exists, skipping kernel rebuild"
    fi
else
    log "Step 6/7: SKIPPED (LYRA_BUILD_KERNELS=0). Set =1 for full install."
fi

# ─────────────────────────────────────────────────────────────
# Step 8: Model weights (gated)
# ─────────────────────────────────────────────────────────────
if [[ "${LYRA_DOWNLOAD_WEIGHTS}" = "1" ]]; then
    if [[ ! -f "${WEIGHTS_SENTINEL}" ]]; then
        if [[ -z "${HF_TOKEN:-}" ]]; then
            warn "HF_TOKEN not set — download may fail if the repo is gated."
        fi
        log "Step 8: downloading weights from ${HF_REPO_ID}"
        pip install --quiet "huggingface-hub>=1.13"
        # huggingface-hub >=1 ships the `hf` CLI; older releases used huggingface-cli.
        if command -v hf >/dev/null 2>&1; then
            HF_HOME="${HF_CACHE_DIR}" hf download \
                "${HF_REPO_ID}" \
                --include "${HF_INCLUDE_PATTERN}" \
                --local-dir "${WEIGHTS_DIR}"
        else
            HF_HOME="${HF_CACHE_DIR}" huggingface-cli download \
                "${HF_REPO_ID}" \
                --include "${HF_INCLUDE_PATTERN}" \
                --local-dir "${WEIGHTS_DIR}"
        fi
        touch "${WEIGHTS_SENTINEL}"
    else
        log "Step 8: weights sentinel exists, skipping download"
    fi
else
    log "Step 8: SKIPPED (LYRA_DOWNLOAD_WEIGHTS=0). Set =1 to download."
fi

# ─────────────────────────────────────────────────────────────
# Step 9: write activation script (every run — keeps it fresh)
# ─────────────────────────────────────────────────────────────
log "Step 9: writing ${ACTIVATE_SCRIPT}"
cat > "${ACTIVATE_SCRIPT}" <<EOF
# Source after every pod start: \`source /workspace/activate.sh\`
source ${CONDA_DIR}/etc/profile.d/conda.sh
conda activate ${ENV_DIR}
export CUDA_HOME=${CUDA_HOME}
SITE=\${CONDA_PREFIX}/lib/python${PYTHON_VERSION}/site-packages
export CPATH="\${CUDA_HOME}/include:\${SITE}/nvidia/cudnn/include:\${SITE}/nvidia/nccl/include\${CPATH:+:\${CPATH}}"
export LD_LIBRARY_PATH="\${CONDA_PREFIX}/lib:\${SITE}/torch/lib:\${SITE}/nvidia/cuda_runtime/lib:\${SITE}/nvidia/cudnn/lib:\${CUDA_HOME}/lib64\${LD_LIBRARY_PATH:+:\${LD_LIBRARY_PATH}}"
export CC="\${CONDA_PREFIX}/bin/x86_64-conda-linux-gnu-gcc"
export CXX="\${CONDA_PREFIX}/bin/x86_64-conda-linux-gnu-g++"
export PATH="\${CUDA_HOME}/bin:\${PATH}"
export HF_HOME=${HF_CACHE_DIR}
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
cd ${REPO_DIR}/Lyra-2
export PYTHONPATH="\${PYTHONPATH:+\${PYTHONPATH}:}."
EOF

log "bootstrap complete. Source the activation script:"
log "  source ${ACTIVATE_SCRIPT}"
