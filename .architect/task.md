# Cycle 5 — task

**Date:** 2026-05-06
**Set by:** architect
**Cycle:** 5

## Goal

Fix the pod's git push auth gap that cycle 4 surfaced. After this cycle, pod-shell can `git push origin voxelo/main` directly from inside the pod, with no local-clone workaround.

## Approach

GitHub deploy key, scoped to `voxeloai/lyra`, write access. Keypair generated on the pod (private key never leaves the volume), public key handed to Vlad to add via the GitHub UI. Then switch the lyra repo's remote from HTTPS to SSH and verify push.

## Steps

1. Generate ed25519 keypair on the pod at `/workspace/.ssh-state/voxelo-lyra-deploy_ed25519`. Keypair lives on the persistent volume so it survives pod stop/start.
2. Configure `git -C /workspace/lyra` with `core.sshCommand` pointing at the new key (with `IdentitiesOnly=yes` so it doesn't fall through to other identities). This setting lives in `.git/config` on the volume — also persistent.
3. Print the public key. Hand to Vlad with instructions: paste into `https://github.com/voxeloai/lyra/settings/keys` → Add deploy key → name it `runpod-lyra-2-pod` → tick "Allow write access".
4. Wait for Vlad's confirmation in chat ("added").
5. Verify: `ssh -T git@github.com -i <key>` should return "Hi voxeloai/lyra! You've successfully authenticated...".
6. Switch remote: `git remote set-url origin git@github.com:voxeloai/lyra.git`.
7. Test push: write the cycle-5 handoff locally, commit, push from inside the pod. Push success is the load-bearing test for this cycle.

## Verification

- `git push origin voxelo/main` from inside the pod completes without prompting for credentials.
- After push, `git log origin/voxelo/main..HEAD` is empty (pod is in sync).
- Re-fetched origin from local clone shows the new commits, no workaround needed.

## Scope

**In scope:**
- Generating keypair on the pod (read-only on Vlad's GitHub side until step 3).
- Configuring the lyra repo's git remote and ssh command.
- Writing handoff + log + committing + pushing.

**Out of scope:**
- Modifying any GitHub repo's deploy keys (Vlad's action only — architect's permission posture forbids).
- Generating the same key for `voxeloai/agent-architect` or `voxeloai/voxelo-brain` (separate cycle if needed).
- Touching the pod's `/root/.ssh/authorized_keys` (that's the inbound RunPod-Key-Go, leave alone).

## Constraints

- Don't reuse the RunPod-Key-Go private key for outbound to GitHub. Separate key, separate purpose.
- Don't print the private key anywhere — only the public key to chat.
- Don't push anything from outside the pod after the keypair is wired up. The whole point is to prove the in-pod path.

## Notes

If the deploy-key approach fails for any reason (org policy, etc.), fallback is a fine-grained PAT in a credential helper. But deploy keys are simpler and per-repo, so default to that.
