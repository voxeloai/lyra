# Cycle 1 — handoff

**Date:** 2026-05-05
**Closed by:** architect (Vlad's local + remote bootstrap, manual SSH in pod)
**Cycle:** 1
**Status:** `done`

## Summary

Cycle 1 goal — get a healthy conda env on the persistent volume, surviving stop/start — passed. The pod can be stopped and restarted with the same volume attached and the env / Python / CUDA / GPU come back without any reinstall.

## What changed

- New `voxeloai/lyra` fork created; `voxelo/main` branch with `.architect/` coordination layer + `scripts/bootstrap.sh` + `scripts/deploy.ps1`.
- `scripts/deploy.ps1` evolved through several iterations to handle: PowerShell native arg quoting (the `--env` JSON), Git-Bash vs WSL bash path translation, conda channel ToS, conda solver fights, multiple-volume name collisions across DCs, `runpodctl datacenter list -o json` parsed via `JavaScriptSerializer`.
- `scripts/bootstrap.sh` evolved to: auto-accept Anaconda channel ToS, install + use libmamba solver, **detect and use the base image's `/usr/local/cuda`** instead of conda installing CUDA, write `activate.sh` with the detected CUDA_HOME baked in.
- Pod created in **EU-RO-1** with volume `06dkw1b4rx` (300 GB, `lyra-workspace`). Pod name `lyra-2`. Image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`.
- Conda env at `/workspace/envs/lyra2`: Python 3.10.20, gcc 13.3.0, eigen, zlib (from conda-forge); PyTorch 2.7.1+cu128 + Lyra-2 `requirements.txt` deps + `MoGe` (git) + `transformer_engine[pytorch]` (from pip).
- `CUDA_HOME=/usr/local/cuda` (system, base image; not conda).

## Verification (load-bearing test)

Run after stop + start of the pod with the same volume:

```
which python                  → /workspace/envs/lyra2/bin/python
python --version              → Python 3.10.20
which nvcc                    → /usr/local/cuda/bin/nvcc
echo $CUDA_HOME               → /usr/local/cuda
python -c "import torch; ..." → torch: 2.7.1+cu128  cuda available: True  cuda version: 12.8
import transformers + diffusers → OK
nvidia-smi                    → H100 80GB visible, 0 GPU util, idle
```

All seven gates passed both before and after a stop/start cycle. Pattern works.

## What worked

- Detecting `/usr/local/cuda` from the base image and skipping the conda CUDA install. **This is the single biggest insight from cycle 1.** It eliminated four cascading conda failures (ToS, missing Linux package, classic-solver fights, libmamba `__win` virtual-package failure).
- libmamba solver (installed in base) for the conda installs that did happen.
- Auto-accepting Anaconda channel ToS at bootstrap start (idempotent).
- Sentinel-gating expensive steps so re-runs are no-ops.
- The activate.sh write at end of bootstrap, sourcing it after every fresh start.

## What didn't (and how we fixed it)

- `scripts/deploy.ps1`: many iterations on PowerShell quoting (env JSON), bash flavour path translation (Git Bash `/c/` vs WSL `/mnt/c/`), volume-name collision across DCs (multiple projects share name), datacenter list JSON parsing (`ConvertFrom-Json` in PS 5.1 collapsed the array). Ended up using `JavaScriptSerializer` for predictable parsing.
- Initial pod image `runpod/pytorch:2.7.1-py3.10-cuda12.8.0-devel-ubuntu22.04` doesn't exist; switched to `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404` (real RunPod template image).
- `nvidia/label/cuda-12.8.0` channel has no Linux package — only Windows. Forced the bypass-conda-CUDA path.

## Open questions for architect

- **Cycle 2 / 3 plan:** kernel builds (Flash Attention 2.6.3 + VIPE + DA3) and weights download. These take 30+ min. Should pod-Claude (Claude Code on the pod) drive cycle 2, or continue the manual SSH-driven approach? The cycle protocol designed for in-pod Claude Code wasn't exercised in cycle 1.
- **Bypass-conda v2:** decision logged at `Architect/decisions/2026-05-05-bypass-conda.md`. After Lyra-2 is fully working, build a v2 bootstrap skeleton that uses uv venv + apt + system CUDA, no conda at all. Test on the next repo deployed under this pattern.

## Next-cycle suggestion

**Cycle 2:** flip kernel builds and weights download on:

```bash
LYRA_BUILD_KERNELS=1 LYRA_DOWNLOAD_WEIGHTS=1 bash scripts/bootstrap.sh
```

Expected: ~30-40 min for Flash Attention build + VIPE + DA3 compile, plus HF download of `nvidia/Lyra-2.0` checkpoints (size unknown, expect tens of GB).

Verification at end of cycle 2: full Lyra-2 import block passes, then run the quick inference command from upstream `INSTALL.md`. Stop/start again to confirm builds + weights survive.

## Pointers

- Log: `.architect/log/2026-05-05-cycle-01.md`
- Bootstrap: `scripts/bootstrap.sh` (sentinel-gated, idempotent)
- Activate: `/workspace/activate.sh` on the pod (written by bootstrap step 9)
- Pattern doc: `Architect/patterns/runpod-persistent-gpu-pod/PATTERN.md`
- Decision log: `Architect/decisions/2026-05-05-bypass-conda.md`
