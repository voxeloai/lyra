# `.architect/` — coordination layer

This directory is how **architect** (running locally on Vlad's machine) and **pod-Claude** (running inside the RunPod pod, in this repo) coordinate. The repo on `voxelo/main` is the message bus; nothing else.

## Files

| File | Owner | Purpose |
|---|---|---|
| `pod-claude/CLAUDE.md` | architect | pod-Claude's persona for this repo |
| `pod-claude/settings.local.template.json` | architect | pod-Claude's permission template |
| `task.md` | architect | current cycle goal — written at cycle open |
| `handoff.md` | pod-Claude | current cycle status — written at cycle close |
| `log/<date>-cycle-<N>.md` | pod-Claude | append-only event log per cycle |
| `RECIPE.md` | architect (final) | locked, reproducible recipe — written when verification all passes |
| `POD-DEPLOY.md` | architect | one-time deploy steps for Vlad (browser/runpodctl) |

## How a cycle runs

1. **Architect writes `task.md`** (or updates it) and pushes.
2. **Vlad SSH's into pod**, `cd /workspace/lyra && claude`. Pod-Claude loads `pod-claude/CLAUDE.md` + reads `task.md`.
3. **Pod-Claude works**, logs continuously to `log/<date>-cycle-<N>.md`.
4. **Pod-Claude writes `handoff.md`** at close and pushes.
5. **Architect pulls**, reads handoff, decides — queue cycle N+1 or lock the recipe.

The full contract is in architect's local memory at `Architect/memory/cycle_protocol.md`.

## Rules

- Architect doesn't edit code in this repo. Only `.architect/`.
- Pod-Claude doesn't edit `task.md`. Only `handoff.md` and `log/`.
- All work on `voxelo/main`. `main` tracks upstream and is fast-forward only.
- Both push, never force-push.
- One cycle at a time. No concurrent writers.
