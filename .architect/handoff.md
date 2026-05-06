# Cycle 5 — handoff

**Date:** 2026-05-06
**Status:** `done`
**Cycle:** 5
**Run by:** pod-shell

## Summary

Pod git push auth fixed. The pod can now `git push origin voxelo/main` directly without prompting and without a local-clone workaround. This commit is the load-bearing test of the fix — if you're reading it on origin, the fix works.

## What changed

- New ed25519 SSH keypair generated on the pod at `/workspace/.ssh-state/pod_id_ed25519` (private key, 256-bit). Public key added to Vlad's GitHub account as an account-level SSH key titled `voxelo-runpod-lyra2-pod` (fingerprint `SHA256:XODcbHD8p1zxvCaRr5PGJLzblxxK90SfxCTtePf3Vpk`). Key authenticates as `visualvlad`.
- Pod's `git -C /workspace/lyra config core.sshCommand` set to `ssh -i /root/.ssh/pod_id_ed25519 -o IdentitiesOnly=yes`. Same setting applied to `~/.gitconfig` (global) so any repo cloned on this pod uses the same key.
- Lyra repo's origin remote switched from `https://github.com/voxeloai/lyra.git` to `git@github.com:voxeloai/lyra.git`.
- The /workspace copy is the persistent source of truth; /root/.ssh holds the chmod-enforced live copy. (MFS doesn't enforce chmod 0600, so the copy in /root/.ssh is what SSH actually uses.)

## Verification

- `ssh -i /root/.ssh/pod_id_ed25519 -T git@github.com`: returned "Hi visualvlad! You've successfully authenticated".
- `git remote -v` on the lyra repo shows the SSH form of origin.
- This handoff being on origin is the proof that `git push origin voxelo/main` from inside the pod works.

## Findings to bank in pod-shell + pattern docs

1. **MFS network filesystem on RunPod doesn't honour chmod 0600.** Private keys placed at `/workspace/.ssh-state/` show world-readable perms regardless. Workaround: copy the key to `/root/.ssh/` on each fresh boot, where chmod is enforceable. The `/workspace` copy is the persistent source; the `/root/.ssh` copy is the live working copy.
2. **`init-pod.sh` should be extended** to copy `/workspace/.ssh-state/pod_id_ed25519` → `/root/.ssh/pod_id_ed25519` on every boot, with the right perms. Without this, after pod stop/start, git push will fail again until manually re-copied. (TODO for next cycle.)
3. **First-time confusion: `RunPod-Key-Go` is NOT the same key as `voxelo_runpod` on Vlad's GitHub.** Their fingerprints differ. The `voxelo_runpod` private key was nowhere obvious on Vlad's Windows or the pod. We pivoted to generating a fresh per-pod ed25519 instead of chasing it. Documented as a pattern note: don't assume a "global GitHub key" is reachable from a fresh pod — generate per-pod credentials instead.
4. **Account-level SSH key vs deploy key:** went with account-level. Trades scope for convenience: this single key works for any of Vlad's GitHub repos this pod ever clones (architect, voxelo-brain, lyra). Acceptable for a single-tenant dev pod under Vlad's account; would not be acceptable for multi-tenant or production.

## Next-cycle suggestion

- **Cycle 6 (small):** update `init-pod.sh` (in voxeloai/lyra `scripts/install-pod-claude.sh` and the architect template) to handle the `/workspace/.ssh-state/` → `/root/.ssh/` copy on boot. One-line addition to the existing init logic. Tests by stopping and starting the pod, then pushing. After this, the auth fix is fully durable across pod restarts.
- After cycle 6, the playbook gap is fully closed and the pattern's deploy steps are honest about the SSH key step.

## Log pointer

Full event log: `.architect/log/2026-05-06-cycle-05.md`.
