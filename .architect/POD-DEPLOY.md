# Pod deployment — one-time setup steps for Vlad

This is what you do once, in your browser and terminal, to bring the pod up. After this, architect (local) and pod-Claude (in-pod) handle the rest via `.architect/`.

**No secret should appear in chat with architect.** All secrets go directly into RunPod's UI or your local CLI configs.

## 0. Prerequisites (your laptop, one-time)

```powershell
# RunPod CLI auth (one-time)
runpodctl config --apiKey <paste-RunPod-key-here>          # writes ~/.runpod/config.toml

# HuggingFace CLI auth (one-time, even if you don't use HF locally)
# Note: huggingface-cli is deprecated in huggingface-hub >=1.0; the new command is `hf`.
hf auth login                                              # writes ~/.cache/huggingface/token

# Verify
runpodctl get pod                                          # should list pods (or empty list, no error)
hf auth whoami                                             # should print your HF username
```

You can confirm to architect that these passed without sharing the keys.

## 1. SSH key for the pod

If you don't already have an SSH key registered to your RunPod account:

```powershell
# Generate a dedicated key (or reuse an existing one)
ssh-keygen -t ed25519 -f ~/.ssh/id_runpod -C "vlad-runpod"

# Copy the public key
cat ~/.ssh/id_runpod.pub
```

Paste the **public** key into RunPod → Settings → SSH Public Keys.

## 2a. (Recommended on Windows) — automated deploy via `scripts\deploy.ps1`

Native PowerShell script — no bash, no jq, no path translation. Calls `runpodctl` for you, creates the volume + pod, sets `HF_TOKEN` on the pod env, prints the SSH command. Idempotent on the volume; refuses to create duplicate pods.

```powershell
# Cache the RunPod key once (persists in ~/.runpod/config.toml)
runpodctl doctor                                  # paste key when prompted

# Per-session: HF_TOKEN in env. Never paste into chat.
$env:HF_TOKEN = "<paste-your-hf-token>"

# Run the deploy
cd C:\Users\v.mulhem\Documents\AI\repos\lyra
.\scripts\deploy.ps1
```

The script auto-discovers a datacenter with H100 SXM 80GB stock. To override: `.\scripts\deploy.ps1 -DataCenter EU-RO-1`. Other parameters at the top of the script.

**On macOS / Linux / VM**, use `bash scripts/deploy.sh` instead — same behaviour, but written for POSIX (requires `jq`).

If you'd rather click through the console, skip to step 2b below.

## 2b. (Manual) — create the network volume in the console

In the RunPod console (browser):

1. Go to **Storage** → **Network Volumes** → **New Network Volume**
2. **Name:** `lyra-workspace`
3. **Size:** **300 GB**
4. **Region:** pick one with H100 SXM stock — typically **EU-RO-1** or **US-KS-1**. If neither has stock, try the dropdown for the region with the highest H100 SXM availability number.
5. Click **Create**

Cost: ~$0.07/GB-month → ~$21/month idle. Don't accidentally create two.

## 3. Deploy the pod

Still in the console:

1. **Pods** → **Deploy** → **Secure Cloud**
2. **GPU:** H100 SXM 80GB, count **1**
3. **Region:** **same region as the volume** (volumes can't cross regions)
4. **Container Image / Template:**
   - Search for: `runpod/pytorch:2.7.1-py3.10-cuda12.8.0-devel-ubuntu22.04`
   - If that exact tag is missing, pick the closest: `runpod/pytorch:2.7.x-py3.10-cuda12.8.x-devel-ubuntu22.04`
   - If nothing matches, use `nvidia/cuda:12.8.0-devel-ubuntu22.04` and accept ~10 min extra in bootstrap step 4
5. **Volume:** attach the network volume `lyra-workspace`. Mount path **`/workspace`**.
6. **Container Disk:** 50 GB (default is fine)
7. **Environment Variables** — this is the secrets step. Add:
   - **Key:** `HF_TOKEN`  | **Value:** _paste your HuggingFace token_
   - That's the only one strictly needed for now. Don't paste the RunPod key here — that's only for outside-pod tooling.
8. **Start Command:** leave default (image's default)
9. **Public IP:** off (we use SSH)
10. **Click Deploy.**

Wait ~30 seconds for the pod to start. Note the **Pod ID**, **SSH command**, and **port** — they show in the pod's row.

## 4. SSH into the pod

```powershell
# Use the SSH command from RunPod's pod page, e.g.:
ssh root@<pod-ip> -p <port> -i ~/.ssh/id_runpod
```

First time you may see a host key prompt — accept it (`yes`).

## 5. Bring the repo and bootstrap

Once SSH'd in, on the pod:

```bash
# Confirm you have a fresh /workspace mounted from the volume
ls -la /workspace

# Clone the Voxelo fork (HTTPS — no SSH key needed for this)
# IMPORTANT: --recursive pulls Lyra-2's vipe and depth_anything_3 submodules,
# which are required for the kernel build in cycle 2. Without --recursive,
# bootstrap.sh now runs `git submodule update --init --recursive` defensively,
# but cloning recursively is still cleaner.
cd /workspace
git clone --recursive https://github.com/voxeloai/lyra.git
cd lyra
git remote add upstream https://github.com/nv-tlabs/lyra.git
git checkout voxelo/main
git submodule update --init --recursive   # belt and braces in case any new submodules landed

# Confirm HF_TOKEN is set (you set it as a pod env var in step 3.7)
[[ -n "$HF_TOKEN" ]] && echo "HF_TOKEN is set" || echo "HF_TOKEN MISSING — fix in pod env"

# Run cycle 1's bootstrap (kernel build + weights both off by default)
bash scripts/bootstrap.sh
```

If bootstrap finishes cleanly:

```bash
source /workspace/activate.sh
which python                                    # /workspace/envs/lyra2/bin/python
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
```

## 6. Start pod-Claude

Still on the pod, install Claude Code if it's not there:

```bash
# Adjust install method to whatever's current on the pod / RunPod template
curl -fsSL https://claude.com/code/install.sh | bash
```

Then:

```bash
cd /workspace/lyra
claude
```

Inside the Claude session, tell it:

> Read `.architect/pod-claude/CLAUDE.md` and `.architect/task.md`. You're cycle 1.

Pod-Claude takes it from there.

## 7. When done with the cycle

- Make sure pod-Claude has committed and pushed.
- Stop the pod from the RunPod console (compute stops; volume persists).
- Tell architect (local): "cycle 1 done, please pull."

## Stop/start later

Whenever you want to resume:

1. RunPod console → Pods → start the (existing) pod, or deploy a new pod with the same volume attached.
2. SSH in.
3. `cd /workspace/lyra && bash scripts/bootstrap.sh` (sentinels skip everything heavy).
4. `source /workspace/activate.sh`.
5. `claude` and continue with the next cycle's `task.md`.

## Decommission (when you're truly done)

1. Stop the pod.
2. (Optional) Copy `/workspace/outputs/` to GCS or local before deleting.
3. Detach + delete the network volume from the console.
