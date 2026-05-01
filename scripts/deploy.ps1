#Requires -Version 5.1
<#
.SYNOPSIS
  Create or attach a RunPod network volume + H100 pod for Lyra-2.

.DESCRIPTION
  Native PowerShell port of scripts/deploy.sh. Idempotent on volume (reuses
  by name); refuses to create a duplicate pod. No bash, no jq — uses
  PowerShell's built-in JSON support.

.PARAMETER PodName / VolumeName / VolumeSizeGB / GpuId / GpuCount / PodImage / ContainerDiskGB / DataCenter / CloudType
  Override defaults. Each also accepts an env-var fallback (POD_NAME, etc.)
  for parity with the bash version.

.NOTES
  Required env vars (set in YOUR shell, never in this file):
    RUNPOD_API_KEY   authenticates runpodctl, OR run: runpodctl doctor (cached)
    HF_TOKEN         passed to the pod for HF model downloads

.EXAMPLE
  $env:HF_TOKEN = "<paste>"
  .\scripts\deploy.ps1

.EXAMPLE
  $env:HF_TOKEN = "<paste>"
  .\scripts\deploy.ps1 -DataCenter EU-RO-1 -PodName lyra-2-debug
#>

[CmdletBinding()]
param(
    [string] $PodName        = $(if ($env:POD_NAME)        { $env:POD_NAME }        else { 'lyra-2' }),
    [string] $VolumeName     = $(if ($env:VOLUME_NAME)     { $env:VOLUME_NAME }     else { 'lyra-workspace' }),
    [int]    $VolumeSizeGB   = $(if ($env:VOLUME_SIZE_GB)  { [int]$env:VOLUME_SIZE_GB }  else { 300 }),
    [string] $GpuId          = $(if ($env:GPU_ID)          { $env:GPU_ID }          else { 'NVIDIA H100 80GB HBM3' }),
    [int]    $GpuCount       = $(if ($env:GPU_COUNT)       { [int]$env:GPU_COUNT }  else { 1 }),
    [string] $PodImage       = $(if ($env:POD_IMAGE)       { $env:POD_IMAGE }       else { 'runpod/pytorch:2.7.1-py3.10-cuda12.8.0-devel-ubuntu22.04' }),
    [int]    $ContainerDiskGB= $(if ($env:CONTAINER_DISK_GB){ [int]$env:CONTAINER_DISK_GB } else { 50 }),
    [string] $DataCenter     = $(if ($env:DATA_CENTER_ID)  { $env:DATA_CENTER_ID }  else { 'auto' }),
    [ValidateSet('SECURE','COMMUNITY')]
    [string] $CloudType      = $(if ($env:CLOUD_TYPE)      { $env:CLOUD_TYPE }      else { 'SECURE' })
)

$ErrorActionPreference = 'Stop'

# Force consistent native-arg passing across PS 5.1 and 7+. In Legacy mode
# (the default), internal double quotes are stripped when calling .exe files
# unless they are backslash-escaped. We escape the env JSON below to survive
# this. Setting this here makes the script behave the same regardless of host.
try { $PSNativeCommandArgumentPassing = 'Legacy' } catch {}

function Log  { param($Msg) Write-Host "[deploy] $Msg" -ForegroundColor Cyan }
function Warn { param($Msg) Write-Host "[deploy] $Msg" -ForegroundColor Yellow }
function Die  { param($Msg) Write-Host "[deploy] $Msg" -ForegroundColor Red; exit 1 }

# ─────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────
if (-not (Get-Command runpodctl -ErrorAction SilentlyContinue)) {
    Die "runpodctl not on PATH. Verify with: where.exe runpodctl"
}
Log "Using runpodctl: $((Get-Command runpodctl).Source)"

if (-not $env:HF_TOKEN) {
    Die 'HF_TOKEN not set. `$env:HF_TOKEN = "<paste-hf-token>"` then re-run.'
}

# Auth: env var OR cached config (~/.runpod/config.toml)
if (-not $env:RUNPOD_API_KEY) {
    $userOut = (runpodctl user 2>&1) | Out-String
    if ($userOut -match '"error"') {
        Warn "runpodctl user returned an error:"
        ($userOut -split "`n") | ForEach-Object { Write-Host "  | $_" }
        Die "Auth failed. Run: runpodctl doctor (paste your API key when prompted)."
    }
    try {
        $user = $userOut | ConvertFrom-Json
        if (-not ($user.id -or $user.email -or $user.userId)) {
            Warn "runpodctl user output did not include id/email:"
            ($userOut -split "`n") | ForEach-Object { Write-Host "  | $_" }
            Die "Auth check failed."
        }
        Log "Account: $($user.email) (balance \$$([math]::Round([double]$user.clientBalance, 2)), spend limit \$$($user.spendLimit))"
    } catch {
        Warn "Could not parse runpodctl user output as JSON:"
        ($userOut -split "`n") | ForEach-Object { Write-Host "  | $_" }
        Die "Auth check failed."
    }
}

# ─────────────────────────────────────────────────────────────
# Pick a data center with H100 stock
# ─────────────────────────────────────────────────────────────
if ($DataCenter -eq 'auto') {
    Log "Discovering datacenter for GPU '$GpuId'"
    try {
        $gpuList = (runpodctl gpu list -o json 2>$null) | ConvertFrom-Json
        $matchingGpu = $gpuList | Where-Object { $_.id -eq $GpuId } | Select-Object -First 1
        $candidates = @()
        if ($matchingGpu -and $matchingGpu.dataCenters) {
            $candidates = @($matchingGpu.dataCenters | ForEach-Object { $_.id } | Sort-Object -Unique)
        }
    } catch {
        $candidates = @()
    }
    if (-not $candidates -or $candidates.Count -eq 0) {
        Warn "Could not auto-discover. Trying common candidates."
        $candidates = @('EU-RO-1','US-KS-2','EU-CZ-1','US-CA-2')
    }
    Log "Candidate DCs: $($candidates -join ', ')"
    $DataCenter = $candidates[0]
}
Log "Using DATA_CENTER_ID=$DataCenter"

# ─────────────────────────────────────────────────────────────
# Network volume — reuse or create
# ─────────────────────────────────────────────────────────────
Log "Looking for existing volume named '$VolumeName'"
$volumeList = @()
try {
    $volumeList = @((runpodctl network-volume list -o json 2>$null) | ConvertFrom-Json)
} catch { $volumeList = @() }

$existingVolume = $volumeList | Where-Object { $_.name -eq $VolumeName } | Select-Object -First 1
if ($existingVolume) {
    $VolumeId = $existingVolume.id
    Log "Reusing volume: $VolumeId"
} else {
    Log "Creating volume: name=$VolumeName size=${VolumeSizeGB}GB dc=$DataCenter"
    $createOut = (runpodctl network-volume create `
        --name $VolumeName `
        --size $VolumeSizeGB `
        --data-center-id $DataCenter `
        -o json 2>&1) | Out-String
    try {
        $created = $createOut | ConvertFrom-Json
        $VolumeId = $created.id
    } catch {
        Die "Volume create returned non-JSON: $createOut"
    }
    if (-not $VolumeId) { Die "Volume create failed: $createOut" }
    Log "Created volume: $VolumeId"
}

# ─────────────────────────────────────────────────────────────
# Pod — refuse duplicates
# ─────────────────────────────────────────────────────────────
$podList = @()
try {
    $podList = @((runpodctl pod list -o json 2>$null) | ConvertFrom-Json)
} catch { $podList = @() }

$existingPod = $podList | Where-Object { $_.name -eq $PodName } | Select-Object -First 1
if ($existingPod) {
    Warn "Pod '$PodName' already exists (id=$($existingPod.id), status=$($existingPod.desiredStatus))."
    Warn "Refusing to create a duplicate. Stop or rename, or pass -PodName <other>."
    return
}

# Build env JSON via PowerShell — never echo the value.
$envJson = @{
    HF_TOKEN = $env:HF_TOKEN
    PYTORCH_CUDA_ALLOC_CONF = 'expandable_segments:True'
} | ConvertTo-Json -Compress

# PowerShell's legacy native-arg passing strips double quotes from arguments
# bound for external .exe files. Escape each `"` as `\"` so the runpodctl
# process receives a literal double quote (PS removes the backslash, native
# Go binary parses the result as valid JSON).
$envJsonArg = $envJson -replace '"', '\"'

# ─────────────────────────────────────────────────────────────
# Create the pod
# ─────────────────────────────────────────────────────────────
Log "Creating pod: name=$PodName gpu=$GpuId x$GpuCount dc=$DataCenter"
Log "  image=$PodImage"
Log "  volume=$VolumeId mount=/workspace size=${VolumeSizeGB}GB"

$podOut = (runpodctl pod create `
    --name $PodName `
    --cloud-type $CloudType `
    --gpu-id $GpuId `
    --gpu-count $GpuCount `
    --container-disk-in-gb $ContainerDiskGB `
    --data-center-ids $DataCenter `
    --network-volume-id $VolumeId `
    --volume-mount-path '/workspace' `
    --image $PodImage `
    --env $envJsonArg `
    --ssh `
    --ports '22/tcp' `
    -o json 2>&1) | Out-String

try {
    $pod = $podOut | ConvertFrom-Json
    $PodId = $pod.id
} catch {
    Die "Pod create returned non-JSON: $podOut"
}
if (-not $PodId) { Die "Pod create failed: $podOut" }

Log "Pod created: $PodId"
Log "Waiting for pod to enter RUNNING status..."

$podInfo = $null
for ($i = 1; $i -le 18; $i++) {
    try {
        $podInfo = (runpodctl pod get $PodId -o json 2>$null) | ConvertFrom-Json
        if ($podInfo.desiredStatus -eq 'RUNNING') { break }
    } catch { }
    Start-Sleep -Seconds 10
}

# ─────────────────────────────────────────────────────────────
# Print connection info
# ─────────────────────────────────────────────────────────────
$ip   = $null
$port = $null
if ($podInfo -and $podInfo.runtime -and $podInfo.runtime.ports) {
    $sshPort = $podInfo.runtime.ports | Where-Object { $_.privatePort -eq 22 } | Select-Object -First 1
    if ($sshPort) {
        $ip   = $sshPort.ip
        $port = $sshPort.publicPort
    }
}

Write-Host ""
Write-Host "[deploy] DONE" -ForegroundColor Green
Write-Host "  pod id:     $PodId"
Write-Host "  status:     $(if ($podInfo) { $podInfo.desiredStatus } else { '?' })"
Write-Host "  volume id:  $VolumeId"
Write-Host ""
Write-Host "SSH:"
Write-Host "  ssh root@$($ip -as [string] -or '<see-runpod-console>') -p $($port -as [string] -or '<see-runpod-console>') -i ~/.ssh/id_runpod"
Write-Host ""
Write-Host "Next steps (on the pod):"
Write-Host "  cd /workspace"
Write-Host "  git clone https://github.com/voxeloai/lyra.git"
Write-Host "  cd lyra"
Write-Host "  git checkout voxelo/main"
Write-Host "  bash scripts/bootstrap.sh"
Write-Host "  source /workspace/activate.sh"
