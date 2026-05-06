# Cycle 6 — task

**Date:** 2026-05-06
**Set by:** architect
**Cycle:** 6

## Goal

Make the cycle 5 git push fix durable across pod stop/start. Right now `/workspace/.ssh-state/pod_id_ed25519` is persistent but `/root/.ssh/pod_id_ed25519` (the chmod-enforced working copy SSH actually uses) is ephemeral. After a pod restart, `git push` will fail again until manually re-copied.

Extend `init-pod.sh` so sourcing it on a fresh boot recreates `/root/.ssh/pod_id_ed25519` (correct perms) and ensures `github.com` is in `/root/.ssh/known_hosts`.

## Verification

The load-bearing test: simulate a post-boot state without doing a real stop/start (which is destructive to this session).

1. Update `init-pod.sh` (both the live `/workspace/init-pod.sh` and the heredoc inside `scripts/install-pod-claude.sh` that generates it).
2. Delete `/root/.ssh/pod_id_ed25519` and `/root/.ssh/known_hosts` (simulating fresh pod state).
3. `source /workspace/init-pod.sh`.
4. Verify: `/root/.ssh/pod_id_ed25519` exists with `0600` perms; `github.com` line in `/root/.ssh/known_hosts`.
5. `ssh -T git@github.com` returns `Hi visualvlad!`.
6. `git -C /workspace/lyra push --dry-run origin voxelo/main` succeeds (or a real push of the cycle 6 artefacts).

## Scope

**In scope:**
- `voxeloai/lyra/scripts/install-pod-claude.sh` — heredoc that writes init-pod.sh
- `/workspace/init-pod.sh` directly on the pod
- Mirror into architect templates if the relevant skeleton exists.

**Out of scope:**
- Any change to the SSH key itself (cycle 5 already settled this).
- Cleaning up old key copies (already done in cycle 5).
- Touching the gh / claude / kb / nlm install logic (separate concern).

## Constraints

- Idempotent: sourcing `init-pod.sh` twice in a row should not error.
- No real pod stop/start during this cycle (would disrupt the session).
- Don't change the key fingerprint or location — only the boot-time copy.

## Notes

After this cycle the cycle-5 fix is fully durable. The pattern's deploy playbook is honest about the SSH key being a one-time setup step, with no recurring "fix it again every restart" cost.
