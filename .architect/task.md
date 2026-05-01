# Cycle 1 — task

**Date:** 2026-05-01
**Set by:** architect
**Cycle:** 1

## Goal

Get the conda env and Python deps in place on the persistent volume, with PyTorch 2.7.1 + CUDA 12.8 working. **Stop before kernel builds (Flash Attention, VIPE, DA3) and weights download.** Those are cycle 2 and 3.

The point of cycle 1: prove the volume mounts, the env activates correctly across pod restarts, the bootstrap script's first 5 sections run cleanly. We don't need a full inference run yet — we need a healthy env that survives stop/start.

## Verification

After running `bash scripts/bootstrap.sh` (with `LYRA_BUILD_KERNELS=0` and `LYRA_DOWNLOAD_WEIGHTS=0`, which are the defaults) and sourcing `/workspace/activate.sh`:

```bash
which python                        # expect: /workspace/envs/lyra2/bin/python
python --version                    # expect: Python 3.10.x
python -c "import torch; print(torch.__version__, torch.cuda.is_available(), torch.version.cuda)"
                                    # expect: 2.7.1+cu128 True 12.8
nvidia-smi                          # expect: H100 80GB visible, no errors
echo $CUDA_HOME                     # expect: /workspace/envs/lyra2
echo $CC                            # expect: ...x86_64-conda-linux-gnu-gcc
```

Then **stop the pod, start a fresh pod with the same volume**, and re-run:

```bash
source /workspace/activate.sh
which python && python -c "import torch; print(torch.__version__)"
```

Expect: same outputs as before, no reinstall needed. **This is the load-bearing test.** If this fails, the persistent-volume pattern is broken; surface it clearly in the handoff.

## Scope

**In scope:**
- `scripts/bootstrap.sh` — fix anything that breaks during a real run
- The conda env at `/workspace/envs/lyra2`
- The activation script at `/workspace/activate.sh`
- `.architect/log/` and `.architect/handoff.md`

**Out of scope:**
- `LYRA_BUILD_KERNELS=1` — leave it 0 for cycle 1
- `LYRA_DOWNLOAD_WEIGHTS=1` — same, 0
- Any code in `Lyra-2/lyra_2/...` — don't touch upstream code yet
- Any inference test — that's cycle 2/3
- The pod's system config beyond what bootstrap step 0 does

## Prior context

This is cycle 1. The repo was just forked from `nv-tlabs/lyra` to `voxeloai/lyra`. INSTALL.md in `Lyra-2/INSTALL.md` is the upstream source of truth; `scripts/bootstrap.sh` is architect's idempotent + sentinel-gated wrapper around it.

The pattern this cycle is part of: `Architect/patterns/runpod-persistent-gpu-pod` (status: `proposed` until verification passes).

## Open questions

- Does the RunPod base image (`runpod/pytorch:2.7.1-py3.10-cuda12.8.0-...` or whatever's available) include Miniconda already? If yes, bootstrap step 1 should detect and skip.
- Is `apt-get update && apt-get install` even needed, or does the base image have everything? Profile this and trim if possible.
- Any environment variables the RunPod base image sets that conflict with our exports? (`CUDA_HOME` in particular.)

If any of these shift the design materially, write it to `handoff.md` so architect can update the pattern doc.

## Constraints

- Don't exceed **2 GPU-hours** of compute on this cycle. If you hit that and the env still isn't healthy, stop and write `blocked` in handoff.
- Don't enable `LYRA_BUILD_KERNELS=1` even if you finish early. Cycle 2 is for that.
- Don't re-download weights even by accident.
- Commit at meaningful checkpoints; don't lose work to disconnects.

## Notes

- Pod-Claude's persona is in `.architect/pod-claude/CLAUDE.md` — read it first.
- The full cycle protocol is described in `.architect/README.md`.
- Architect (local) will not see your edits in real-time. Push commits often.
