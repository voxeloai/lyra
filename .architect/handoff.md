# Cycles 2 + 3 — handoff

**Date:** 2026-05-05
**Status:** `done` — pattern fully tested
**Cycles:** 2 (kernel builds + weights) and 3 (actual inference) collapsed into one writeup since both ran in the same in-pod session.

## Summary

Lyra-2 ran end-to-end on a RunPod H100 SXM pod with a persistent volume. Three videos generated from `assets/samples/04.png` using DMD 4-step distillation. Full deploy pipeline proven cycle 1 → 2 → 3 over 5 days (2026-05-01 to 2026-05-05). The `runpod-persistent-gpu-pod` pattern is now `tested` and the lessons are baked into the templates for the next repo.

See `RECIPE.md` for the locked, reproducible procedure.

## Cycle 2 outcome

- Flash Attention 2.6.3 built in env
- VIPE editable install built (after submodule init)
- Depth Anything 3 [gs] built (after pre-installing hatchling/pathspec/editables)
- 91 GB of weights downloaded from `nvidia/Lyra-2.0`
- All builds + weights survive a pod stop/start (load-bearing test passed in cycle 1, still proven for kernel binaries here)
- `/workspace/.build-complete-v1` and `/workspace/.weights-complete` sentinels written

## Cycle 3 outcome

- Inference command: `python -m lyra_2._src.inference.lyra2_zoomgs_inference --input_image_path assets/samples --sample_id 4 --experiment lyra2 --use_dmd --prompt "Cinematic 3D camera movement through the scene"` with `NVTE_FUSED_ATTN=0`
- Total time: ~4 minutes on H100 (DMD 4-step distillation)
- Output:
  - `inference/lyra2_zoomgs/04/zoom_in.mp4` (81 frames)
  - `inference/lyra2_zoomgs/04/zoom_out.mp4` (241 frames)
  - `inference/lyra2_zoomgs/videos/04.mp4` (combined, 322 frames)

## Issues encountered + fixed in cycles 2/3

(All banked in `agent-architect/memory/playbook_repo_deploy.md`)

1. Submodules — `vipe` and `depth_anything_3` directories empty without `--init --recursive`. Bootstrap now runs `git submodule update --init --recursive` defensively.
2. Hatchling missing `pathspec` — DA3's `pip install -e --no-build-isolation` failed because `--no-build-isolation` uses the env's hatchling, but pathspec wasn't installed. Bootstrap now pre-installs `hatchling pathspec editables`.
3. Weights at separate path — Lyra has hardcoded `checkpoints/...` relative paths but we put weights at `/workspace/weights/`. Bootstrap step 8a symlinks them.
4. peft missing — non-fatal warning blocks `--use_dmd`. Pre-installed in step 5.
5. `hf_transfer` required — base image sets `HF_HUB_ENABLE_HF_TRANSFER=1`; transformers downloads tokenizers at runtime. Pre-installed in step 5.
6. Hydra `MissingConfigException` — script default `lyra_framepack_spatial` doesn't exist in the released configs. Pass `--experiment lyra2` (the only available).
7. Caption source required — Lyra defaults to Gemini captioning. Pass `--prompt "<text>"` for smoke tests.
8. **cuDNN sublibrary loading failure** — `transformer_engine` fused attention can't find cuDNN sublibs at runtime. Bypassed with `NVTE_FUSED_ATTN=0`. Proper fix not pursued (bypass is sufficient for inference, slight perf cost).

## Sentinels in place on the volume

```
/workspace/.build-complete-v1     (touched after Flash Attention + VIPE + DA3 all built)
/workspace/.weights-complete      (touched after HF download)
/workspace/activate.sh            (sources conda, sets CUDA_HOME, exports paths)
/workspace/envs/lyra2/            (full conda env, ~10 GB)
/workspace/weights/checkpoints/   (six subdirs: image_encoder, lora, model, recon, text_encoder, vae; 91 GB)
/workspace/lyra/                  (the repo with .architect/ + scripts/)
/workspace/hf-cache/              (HF Hub cache for runtime tokenizer/model downloads)
```

## Next steps (post-cycle-3)

1. Pattern flips to `tested`. PATTERN.md updated, templates carry all the cycle 1-3 fixes.
2. Vlad uses the pod for actual Lyra-2 experimentation. Pod stop/start works freely.
3. `decisions/2026-05-05-runpod-pgpu-tested.md` logged in agent-architect.
4. Bypass-conda v2 still pending — design exists, build the v2 skeleton and test on the next repo.

## Total time bank

- 2026-05-01: deploy infrastructure (deploy.ps1 + scaffolding) — ~6 hours of debugging PowerShell quoting, JSS parsing, runpodctl quirks
- 2026-05-05: bootstrap + cycles 2+3 — ~4 hours of debugging conda + transformer_engine + cudnn + Hydra + prompts
- Total: ~3 calendar days, ~10 active engineering hours, all banked

Repo N+2 (next deploy under this pattern) target: cycle 1 in under 4 hours.
