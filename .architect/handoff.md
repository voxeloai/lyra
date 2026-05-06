# Cycle 6 — handoff

**Date:** 2026-05-06
**Status:** `done`
**Cycle:** 6
**Run by:** pod-shell

## Summary

Cycle 5's git push fix is now durable across pod stop/start. `init-pod.sh` recreates the `/root/.ssh/pod_id_ed25519` working copy from the persistent `/workspace/.ssh-state/` source on every boot, plus ensures `github.com` is in `known_hosts`. After this cycle, pod restart needs only `source /workspace/init-pod.sh` to restore push capability — no manual cp.

## What changed

- `voxeloai/lyra/scripts/install-pod-claude.sh` — the heredoc that generates `init-pod.sh` now includes the SSH-key restoration block.
- `/workspace/init-pod.sh` on the pod — rewritten directly with the new logic so the fix is immediately live (didn't require a full re-run of install-pod-claude.sh).
- Architect's pattern template `agent-architect/patterns/runpod-persistent-gpu-pod/templates/install-pod-claude.sh.skeleton` mirrored.

The new block (in `init-pod.sh`):
```bash
SSH_KEY_SRC="${WORKSPACE}/.ssh-state/pod_id_ed25519"
SSH_KEY_DST="/root/.ssh/pod_id_ed25519"
if [ -f "$SSH_KEY_SRC" ]; then
    mkdir -p /root/.ssh && chmod 700 /root/.ssh
    if [ ! -f "$SSH_KEY_DST" ] || ! cmp -s "$SSH_KEY_SRC" "$SSH_KEY_DST"; then
        cp "$SSH_KEY_SRC" "$SSH_KEY_DST"
    fi
    chmod 600 "$SSH_KEY_DST"
    if ! grep -qE '^github\.com ' /root/.ssh/known_hosts 2>/dev/null; then
        ssh-keyscan -t ed25519,rsa github.com 2>/dev/null >> /root/.ssh/known_hosts
        sort -u /root/.ssh/known_hosts -o /root/.ssh/known_hosts 2>/dev/null || true
    fi
fi
```

## Verification

Simulated post-boot state (deleted live key + github.com from known_hosts), sourced init-pod.sh, all six checks passed:

| step | result |
|---|---|
| key recreated | `/root/.ssh/pod_id_ed25519` exists, perms `-rw-------` |
| known_hosts populated | `github.com` line present |
| SSH probe | "Hi visualvlad! You've successfully authenticated" |
| `git push --dry-run` | "Everything up-to-date" |
| idempotent re-source | runs without error |
| this commit reaching origin | proves the path end-to-end |

## What worked

- Direct rewrite of `/workspace/init-pod.sh` (without re-running the full install) is the right move when only the init-pod heredoc changes. Faster, no risk of side-effects from the npm/uv/etc. install paths.
- `cmp -s` guard for the key copy makes the cp a no-op when the working copy is already current. Cheap idempotency.

## What didn't work / findings

- **PowerShell `$(wc -l < file)` inside an SSH command argument with backtick escaping** got mangled — bash on the remote saw a syntax error from the half-expanded `$(`. Workaround: keep the post-write check in a separate SSH invocation with no PS variable expansion. Banked into pod-shell.md primitives (already noted under "stage script via stdin" pattern).
- The previous pod's `/root/.ssh/known_hosts` had a single line for the runpod inbound host, no github.com — confirming that without the init-pod.sh fix, every fresh pod boot would have failed on the first `git push` due to the host-key prompt.

## Next-cycle suggestion

The runpod-persistent-gpu-pod pattern is now fully durable end-to-end:
- Cycle 1-3: env build, weights, inference recipe.
- Cycle 4: recipe re-verified post-volume-migration.
- Cycle 5: in-pod git push working.
- Cycle 6: in-pod git push survives pod restart.

Open candidates for a future cycle (none urgent):

- **Cycle 7a:** real stop/start of this pod to confirm cycle 6's fix works against a true fresh boot rather than a simulation. Cheap (~10 min), high confidence dividend.
- **Cycle 7b:** deploy a second repo under the pattern (the calibration target). Test that the playbook is repeatable on a fresh pattern instance.
- **Cycle 7c:** lift cycles 4-6 learnings into `RECIPE.md` (cold-cache cost, idempotency note, per-pod SSH key setup as required step) so anyone reading just `RECIPE.md` gets the full picture.

I'd take 7c first (cheap, makes the recipe honest), then 7b (the real test of the pattern's reusability).

## Log pointer

Full event log: `.architect/log/2026-05-06-cycle-06.md`.
