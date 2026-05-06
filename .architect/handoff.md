# Cycle 4 — handoff

**Date:** 2026-05-06
**Status:** `done` (recipe verified; outputs not regenerated — see findings)
**Cycle:** 4
**Run by:** pod-shell (architect's SSH sub-agent, default mode as of 2026-05-06)

## Summary

First real cycle driven via SSH sub-agent (pod-shell) on the pivoted pod (`whtrti3gc8nptl` in AP-JP-1, volume `0oleomzwlz`). The locked cycle 3 inference command from `RECIPE.md` ran end-to-end with exit code 0 in ~14 min wall clock. The recipe still works.

## What changed

- Wrote `.architect/task.md` for cycle 4 (architect-side).
- Drove the locked inference command (`PYTHONPATH=. python -m lyra_2._src.inference.lyra2_zoomgs_inference --input_image_path assets/samples --sample_id 4 --experiment lyra2 --use_dmd --prompt "Cinematic 3D camera movement through the scene"`) inside tmux session `arch` via a staged `/tmp/cycle4.sh` script (avoids quoting hell).
- Inference loaded the model, set up the DA3 + MoGe + DMD pipeline, hit the script's idempotency guard, and exited cleanly.

## Verification

- Process exit: **0**
- Wall clock: ~14 min (started 09:58:41 UTC, finished 10:12:35 UTC)
- Output side-effect: **none** — script detected existing `inference/lyra2_zoomgs/videos/04.mp4` from cycle 3 and skipped sampling. Existing files at `inference/lyra2_zoomgs/04/` (zoom_in.mp4, zoom_out.mp4, combined.mp4 etc.) are untouched, May 5 timestamps preserved.
- `tmux session 'arch'`: still alive at cycle close.

## What worked

- AP-JP-1 migrated volume is fully functional: 91 GB of weights + dcp model checkpoint + DA3 + MoGe all load.
- Env activates cleanly via `/workspace/activate.sh`.
- All cycle-3 imports + inference module reachable.
- pod-shell's primitives (SSH for one-shots, tmux send-keys + capture-pane for long ops, stdin-piped script staging) all worked.

## What didn't work / findings

1. **Cold-cache MFS load is ~14 min vs cycle 3's ~4 min on a warm pod.** First inference after a volume migration / fresh pod start pays a one-time read cost: model checkpoint loading from `mfs#ap-jp-1.runpod.net:9421` plus torch.compile() warm-up (32 inductor compile workers spawned). Subsequent runs on this pod should be back to cycle-3 speed. Worth banking in `RECIPE.md` as an expected first-run cost.
2. **Inference is idempotent — skips when `inference/lyra2_zoomgs/videos/<id>.mp4` exists.** Not a bug; correct behaviour. To force a re-run, delete the existing combined video first or pass an overwrite flag (need to check upstream code).
3. **Pod git push fails — pod has no GitHub credentials.** The cycle-4 task.md commit (`efd9797`) is local to the pod only; push returned `fatal: could not read Username for 'https://github.com'`. Pre-pivot install-pod-claude.sh solved this with `gh auth login`. The new SSH-sub-agent default needs a separate path: either gh auth on first pod boot, or switch the remote to SSH + GitHub-add-pod-key, or push via Vlad's local clone. Banking as a playbook gap (see open questions).
4. **PowerShell → ssh → tmux send-keys quoting is fragile.** Spaces inside the prompt mangled the first attempt. Reliable workaround: stage the command in a `/tmp/<cycle>.sh` file via stdin heredoc, then `tmux send-keys "bash /tmp/<cycle>.sh" Enter`. This pattern should be added to `pod-shell.md` primitives.
5. **`pgrep -f` inside outer heredocs can return spurious empty results.** Use `ps -p <pid>` against a known PID instead. Banking as a reliability note.

## Open questions for architect

- **How should pod git push auth work in default SSH-sub-agent mode?** Three options: (a) require `gh auth login` on first pod boot like the autonomous-mode path; (b) switch the pod's git remote to SSH (`git@github.com:voxeloai/lyra.git`) and add the pod's SSH key to GitHub; (c) have pod-shell write artefacts to the pod, then have architect (local) pull from the pod via scp + push from local. Recommend (b) — once-only setup, cleanest, no recurring auth.
- **Should `RECIPE.md` document the cold-cache load time as an expected first-run cost?** I think yes.
- **Should pod-shell's primitives section get the "stage script via stdin" pattern added?** Yes, banking now.

## Next-cycle suggestion

Pick one:
- **Cycle 5a:** Resolve push auth (option b above), then re-run cycle 4 to confirm push works end-to-end.
- **Cycle 5b:** Force a re-generation of sample_id 4 (delete existing, re-run, compare file sizes to the May 5 baseline) to prove the cold-cache hot-path matches cycle 3.
- **Cycle 5c:** Skip both; pattern is sufficiently re-verified. Move on to deploying a second repo under the pattern (the calibration target).

I'd take 5a — push auth is a real blocker for any future cycle that needs to land artefacts on origin.

## Log pointer

Full event log: `.architect/log/2026-05-06-cycle-04.md`.
