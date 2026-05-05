# Cycle 2 — task

**Date:** 2026-05-05
**Set by:** architect
**Cycle:** 2

## Goal

Build the custom CUDA kernels (Flash Attention 2.6.3, VIPE, Depth Anything 3) and download the `nvidia/Lyra-2.0` model weights. After this cycle, all the heavy artefacts live on the volume, and a stop/start cycle should still work.

## Verification

After running bootstrap with both phase flags on:

```bash
LYRA_BUILD_KERNELS=1 LYRA_DOWNLOAD_WEIGHTS=1 bash scripts/bootstrap.sh
```

(Expect ~30-40 min for kernel builds + weights download. Don't stop the pod mid-build.)

Then source activate and run the upstream `INSTALL.md` verification block:

```bash
source /workspace/activate.sh
PYTHONPATH=. python -c "
import torch, flash_attn, transformer_engine.pytorch, vipe_ext, depth_anything_3.api, moge.model.v1
print('torch:', torch.__version__, '| cuda:', torch.cuda.is_available())
print('all imports OK')
"
PYTHONPATH=. python -m lyra_2._src.inference.lyra2_zoomgs_inference --help
PYTHONPATH=. python -m lyra_2._src.inference.vipe_da3_gs_recon --help
```

All three should run without errors.

Then stop the pod, start it fresh, and re-run JUST:

```bash
source /workspace/activate.sh
PYTHONPATH=. python -c "import flash_attn; import vipe_ext; import depth_anything_3.api; print('survived stop/start')"
ls -lah /workspace/weights/
```

Both must work without re-running bootstrap.

## Scope

**In scope:**
- `scripts/bootstrap.sh` — fix anything that breaks during kernel builds
- The `/workspace/.build-complete-v1` sentinel — must be written only after ALL three kernels build successfully
- The `/workspace/.weights-complete` sentinel — must be written only after the HF download completes

**Out of scope:**
- Running actual inference on real data (cycle 3)
- Code changes inside `Lyra-2/lyra_2/` upstream (don't touch unless explicitly debugging a build error)
- Switching to bypass-conda — that's the v2 pattern, separate work

## Prior context

Cycle 1 (handoff: `.architect/handoff.md`, log: `.architect/log/2026-05-05-cycle-01.md`) proved the base env survives stop/start. CUDA_HOME is `/usr/local/cuda` (system); the conda env at `/workspace/envs/lyra2` has Python 3.10.20 + gcc 13.3 + PyTorch 2.7.1+cu128 + Lyra deps.

Cycle 2 layers on the slow stuff. **Flash Attention 2.6.3** is built with `MAX_JOBS=16 pip install --no-build-isolation --no-binary :all: flash-attn==2.6.3`. **VIPE** is `pip install --no-build-isolation -e 'lyra_2/_src/inference/vipe'` with `USE_SYSTEM_EIGEN=1`. **Depth Anything 3** is `pip install --no-build-isolation -e 'lyra_2/_src/inference/depth_anything_3[gs]'`.

These need: `nvcc` on PATH (yes, activate.sh adds `$CUDA_HOME/bin`), gcc 13.3 (in conda env), CUDA headers (yes, `$CUDA_HOME/include` in CPATH), eigen (in conda env via `eigen` package).

## Open questions

- Is gcc 13.3 from conda compatible with CUDA 12.8.1's nvcc? Lyra tested gcc 13.3 + cuda 12.8.0; the system cuda is 12.8.1 (close enough most likely).
- Will Flash Attention 2.6.3 take more than the default GitHub action timeout to build? Locally we can let it run as long as needed but watch the H100 burn rate ($2.99/hr × ~30 min build = ~$1.50).
- Weights size for `nvidia/Lyra-2.0`: not documented. If it's >250 GB the 300 GB volume gets tight. Be prepared to expand the volume if `df -h /workspace` shows danger.

## Constraints

- **Cap GPU-time at 90 minutes** for this cycle. If kernel build + weights take longer, write `blocked` in handoff and surface what's slow.
- **Don't change CUDA_HOME** mid-build (would invalidate the build).
- **Push to `voxelo/main`** at meaningful checkpoints — don't let an hour of progress sit unpushed.

## Notes

- Pod-Claude can drive this cycle from inside the pod if Vlad wants to test the cycle protocol end-to-end. Or continue manual SSH if simpler.
- After cycle 2 lands, cycle 3 = run the actual inference quick test, then declare the pattern `tested` and write `RECIPE.md`.
