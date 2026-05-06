# Cycle 4 — task

**Date:** 2026-05-06
**Set by:** architect
**Cycle:** 4

## Goal

Re-verify the cycle 3 inference recipe runs end-to-end on the AP-JP-1 migrated pod. This is the first real cycle driven by the new `pod-shell` SSH sub-agent (default mode as of 2026-05-06). Same input, same prompt, same expected outputs as cycle 3 — but now executed via tmux send-keys rather than an in-pod Claude.

## Verification

Run the locked inference command from `RECIPE.md`:

```bash
source /workspace/activate.sh
cd /workspace/lyra/Lyra-2
export NVTE_FUSED_ATTN=0
PYTHONPATH=. python -m lyra_2._src.inference.lyra2_zoomgs_inference \
    --input_image_path assets/samples \
    --sample_id 4 \
    --experiment lyra2 \
    --use_dmd \
    --prompt "Cinematic 3D camera movement through the scene"
```

Pass criteria:
- Process exits 0 within 8 minutes wall clock.
- Three video files produced at `inference/lyra2_zoomgs/04/`: `zoom_in.mp4`, `zoom_out.mp4`, and a combined output.
- Each `.mp4` non-zero size and ffprobe-readable (frame count present).

## Scope

**In scope:**
- Driving the inference run via tmux on session `arch`.
- Appending to `.architect/log/2026-05-06-cycle-04.md` continuously.
- Writing `.architect/handoff.md` with status at cycle close.
- Committing and pushing on `voxelo/main`.

**Out of scope:**
- Any code edits in `Lyra-2/` source.
- Re-downloading weights.
- Touching `bootstrap.sh`, `RECIPE.md`, or anything in `.architect/pod-claude/` (autonomous-mode artefacts).
- Modifying the upstream-tracking `main` branch.

## Prior context

Cycle 3 (2026-05-05) ran this exact command in ~4 min on the EU-RO-1 pod and produced three videos. See cycles 2+3 handoff in repo history. The volume was migrated to AP-JP-1 on 2026-05-06; the new pod (`whtrti3gc8nptl`) was deployed today. Smoke test (cycle-3 imports) passed earlier this session — env, weights, and CUDA stack are intact.

## Open questions

- Does ffprobe agree the videos are well-formed, or just that they exist?
- Do file sizes land in the same ballpark as cycle 3 (we don't have those numbers logged precisely; record this run's sizes as the baseline going forward).

## Constraints

- Hard cap: 8 GPU-minutes (cycle 3 took ~4 — anything over 8 means something regressed; abort and surface).
- No new pip installs. Anything missing means env drift; surface it in handoff and stop.
- No new pod creation. We're working inside the existing live pod.

## Notes

This cycle is also a smoke test of pod-shell's discipline: drive long-running work through tmux, capture output incrementally, leave the tmux session intact at close, commit + push from the pod.
