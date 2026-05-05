# RECIPE — Lyra-2 on RunPod H100 SXM with persistent volume

**Status:** tested 2026-05-05. Reproducible from scratch in ~4 hours including build + weights download.

This is the locked, reproducible recipe for getting NVIDIA's Lyra-2 running on a RunPod GPU pod with a persistent network volume that survives stop/start. Built and tested across cycles 1-3.

## Prerequisites (one-time, on your laptop)

- RunPod account with Voxelo team API key (`runpodctl doctor`)
- HuggingFace token (`hf auth login` — for downloading `nvidia/Lyra-2.0` model weights)
- GitHub auth (`gh auth login`)
- `runpodctl` (~/.local/bin), `jq` (~/.local/bin or system)
- For PowerShell deploy on Windows: PS 5.1+ or 7+

## Deploy

From `Documents/AI/repos/lyra` (clone of `voxeloai/lyra`):

```powershell
$env:HF_TOKEN = "<your-hf-token>"
.\scripts\deploy.ps1
```

Or to pin a DC (e.g. EU-RO-1 for the existing volume):

```powershell
.\scripts\deploy.ps1 -DataCenter EU-RO-1
```

Script auto-discovers a volume-capable DC with H100 SXM 80GB stock (sorted High → Low), reuses an existing `lyra-workspace` volume if found in that DC, otherwise creates a 300 GB volume. Creates the pod with image `runpod/pytorch:1.0.2-cu1281-torch280-ubuntu2404`, attaches the volume at `/workspace`, sets `HF_TOKEN` as a pod env var, retries pod create up to 6× on stock issues.

Outputs: pod ID, volume ID, SSH command.

## On the pod (cycle 1: env health)

```bash
ssh root@<ip> -p <port> -i ~/.ssh/id_runpod

# Inside tmux so disconnects don't kill long builds
apt-get install -y tmux
tmux new -s build

cd /workspace
git clone --recursive https://github.com/voxeloai/lyra.git
cd lyra
git checkout voxelo/main

bash scripts/bootstrap.sh    # phase flags off; ~5 min
source /workspace/activate.sh

# Verify
which python                 # /workspace/envs/lyra2/bin/python
python -c "import torch; print(torch.__version__, torch.cuda.is_available())"
nvidia-smi
```

Stop the pod from RunPod console, start it back up, SSH in, `source /workspace/activate.sh` and re-verify. Same outputs == cycle 1 done.

## On the pod (cycle 2: kernels + weights, ~30-40 min)

```bash
tmux new -s build
cd /workspace/lyra
LYRA_BUILD_KERNELS=1 LYRA_DOWNLOAD_WEIGHTS=1 bash scripts/bootstrap.sh
```

What runs:
- Flash Attention 2.6.3 (~10-15 min build with MAX_JOBS=16)
- VIPE editable install (~2 min build)
- Depth Anything 3 [gs] editable install (~2-5 min build)
- HuggingFace download of `nvidia/Lyra-2.0` checkpoints (91 GB, time depends on DC bandwidth)
- `peft`, `hf_transfer`, `hatchling`, `pathspec`, `editables` pre-installed
- Symlink `Lyra-2/checkpoints` → `/workspace/weights/checkpoints`

Verify after:

```bash
source /workspace/activate.sh
PYTHONPATH=. python -c "
import torch, flash_attn, transformer_engine.pytorch, vipe_ext, depth_anything_3.api, moge.model.v1
print('all imports OK')
"
```

Stop, start, re-verify same imports without re-running bootstrap. Survival proves the pattern.

## On the pod (cycle 3: actual inference)

```bash
source /workspace/activate.sh
cd /workspace/lyra/Lyra-2

# Bypass the cuDNN sublibrary loading issue by disabling TE fused attention.
# (See known issues below for the proper fix.)
export NVTE_FUSED_ATTN=0

# DMD 4-step distillation gives ~4 min total inference. Without --use_dmd: ~9 min.
PYTHONPATH=. python -m lyra_2._src.inference.lyra2_zoomgs_inference \
    --input_image_path assets/samples \
    --sample_id 4 \
    --experiment lyra2 \
    --use_dmd \
    --prompt "Cinematic 3D camera movement through the scene"
```

Output: three video files at `inference/lyra2_zoomgs/04/`:
- `zoom_in.mp4` (81 frames)
- `zoom_out.mp4` (241 frames)
- combined at `inference/lyra2_zoomgs/videos/04.mp4` (322 frames)

## Stop / start cycle (proven)

After all three cycles, the pod can be stopped from the RunPod console (compute charges drop, volume persists at ~$30/mo for 300 GB) and restarted later. On restart, only `source /workspace/activate.sh` is needed before running inference. No bootstrap re-run required.

## Known issues / quirks (banked in the playbook)

- **`NVTE_FUSED_ATTN=0` required.** The cuDNN sublibrary loading fails inside transformer_engine's fused-attention path. Bypass works fine; proper fix is `pip install --upgrade --force-reinstall nvidia-cudnn-cu12` + reinstall `transformer_engine[pytorch]`. Untested; the bypass is sufficient for inference.
- **Hydra config name mismatch.** Pass `--experiment lyra2` (the only available); script default `lyra_framepack_spatial` doesn't exist in the released configs.
- **Caption required.** Lyra defaults to Gemini auto-captioning. Pass `--prompt "<text>"` for smoke tests, or set up a Gemini key for real use.
- **Submodules.** `git clone --recursive` is essential; bootstrap also runs `git submodule update --init --recursive` defensively.
- **Weights at `/workspace/weights/`, not in repo.** Bootstrap symlinks `Lyra-2/checkpoints` so Lyra's hardcoded relative paths resolve.

## Costs (proven envelope)

- Volume idle: ~$30/mo (300 GB)
- Pod compute when running: $2.99/hr (H100 SXM 80GB Secure Cloud)
- Bootstrap (cycles 1+2): ~$3 in compute
- Inference per video (DMD 4-step): ~$0.20 per generation
- Stopping the pod drops charges to volume-only

## Pattern reference

`runpod-persistent-gpu-pod` from `voxeloai/agent-architect`. This deployment is the first instance and the proof. Future repo deploys under this pattern reuse the templates from `agent-architect/patterns/runpod-persistent-gpu-pod/templates/`.
