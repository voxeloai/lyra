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

# IMPORTANT: keep at 'Continue' so native commands (runpodctl) writing to
# stderr don't terminate the script. We capture stderr via 2>&1 and inspect
# the output ourselves; explicit `Die` calls handle real failures.
$ErrorActionPreference = 'Continue'

# In PS 7.3+, native command errors are wrapped as PowerShell errors that
# respect $ErrorActionPreference unless this is set to $false.
try { $PSNativeCommandUseErrorActionPreference = $false } catch {}

# Force consistent native-arg passing across PS 5.1 and 7+. In Legacy mode
# (the default), internal double quotes are stripped when calling .exe files
# unless they are backslash-escaped. We escape the env JSON below to survive
# this.
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
# Network volume — reuse or create. We check this FIRST because if a volume
# already exists, the pod must run in the volume's datacenter — that overrides
# any auto-discovery.
# ─────────────────────────────────────────────────────────────
Log "Looking for existing volume named '$VolumeName'"
$volumeList = @()
try {
    $volumeList = @((runpodctl network-volume list -o json 2>$null) | ConvertFrom-Json)
} catch { $volumeList = @() }

# Collect ALL matches by name. Use array indexing rather than Select-Object
# -First 1 to defeat any pipeline-flattening surprises in PS 5.1.
$matchingVolumes = @($volumeList | Where-Object { $_.name -eq $VolumeName })
$VolumeId = $null

if ($matchingVolumes.Count -eq 0) {
    # No existing volume — we'll create one below after picking a DC.
}
elseif ($matchingVolumes.Count -gt 1) {
    Warn "Found $($matchingVolumes.Count) volumes named '$VolumeName' from prior failed runs:"
    foreach ($v in $matchingVolumes) {
        $vDc = $v.dataCenterId; if (-not $vDc) { $vDc = $v.dataCenter }; if (-not $vDc) { $vDc = '?' }
        Warn ("  - id={0,-12}  dc={1}" -f $v.id, $vDc)
    }
    Warn "Refusing to pick one automatically - these are orphans burning idle volume cost."
    Warn "Clean up with:"
    foreach ($v in $matchingVolumes) {
        Warn ("  runpodctl network-volume delete {0}" -f $v.id)
    }
    Die "Multiple '$VolumeName' volumes exist. Delete all-but-one (or all and let the script create fresh), then re-run."
}
else {
    $existingVolume = $matchingVolumes[0]
    $VolumeId = [string]$existingVolume.id
    $existingDc = $existingVolume.dataCenterId
    if (-not $existingDc) { $existingDc = $existingVolume.dataCenter }
    if (-not $existingDc) { $existingDc = $existingVolume.location }
    $existingDc = [string]$existingDc

    if ($existingDc) {
        if ($DataCenter -ne 'auto' -and $DataCenter -ne $existingDc) {
            Warn "Requested -DataCenter $DataCenter but the existing volume '$VolumeName' lives in $existingDc."
            Warn "Network volumes can't move DCs. Either delete the volume and re-run, or use a different VolumeName."
            Die "DC mismatch."
        }
        $DataCenter = $existingDc
        Log "Reusing volume: $VolumeId (locked to DC: $DataCenter)"
    } else {
        Log "Reusing volume: $VolumeId  (DC could not be read from JSON)"
    }
}

# ─────────────────────────────────────────────────────────────
# Pick a data center with stock — only if we're creating a fresh volume.
# Print candidates with whatever availability fields the JSON gives us, so
# the choice is transparent and we can re-run with -DataCenter if needed.
# ─────────────────────────────────────────────────────────────
function Show-DcCandidates {
    param([array] $DataCenters)
    foreach ($d in $DataCenters) {
        $bits = @("id=$($d.id)")
        if ($null -ne $d.available)        { $bits += "available=$($d.available)" }
        if ($null -ne $d.availability)     { $bits += "availability=$($d.availability)" }
        if ($null -ne $d.stock)            { $bits += "stock=$($d.stock)" }
        if ($null -ne $d.gpuAvailability)  { $bits += "gpuAvailability=$($d.gpuAvailability)" }
        if ($null -ne $d.location)         { $bits += "location=$($d.location)" }
        Log "  - $($bits -join '  ')"
    }
}

# Datacenters that currently support network volumes. RunPod's error message
# revealed this list 2026-05-01; if RunPod expands volume support, edit here.
$VolumeSupportedDCs = @(
    'AP-JP-1','CA-MTL-3','CA-MTL-4','EU-CZ-1','EU-NL-1','EU-RO-1','EU-SE-1',
    'EUR-IS-1','EUR-IS-3','EUR-NO-1','US-CA-2','US-GA-2','US-IL-1','US-KS-2',
    'US-MO-1','US-MO-2','US-NC-2','US-NE-1','US-TX-3','US-WA-1'
)

if ($DataCenter -eq 'auto') {
    # Walk datacenter list. Each DC has gpuAvailability[] of { gpuId, stockStatus }.
    # The DC scan is the source of truth; we don't pre-check gpu list.
    Log "Scanning datacenters for stock of '$GpuId'"
    $dcList = @()
    try { $dcList = @((runpodctl datacenter list -o json 2>$null) | ConvertFrom-Json) } catch {}

    # Use a rank map to assign sort priority. Compute SortKey OUTSIDE the
    # hashtable literal to avoid PS 5.1's quirks with `if` expressions inside
    # hashtable values (which is suspected of corrupting earlier runs).
    $rank = @{ 'High' = 1; 'Medium' = 2; 'Low' = 3 }
    $candidates = New-Object System.Collections.ArrayList
    foreach ($dc in $dcList) {
        if (-not $dc.gpuAvailability) { continue }
        $entry = $dc.gpuAvailability | Where-Object { $_.gpuId -eq $GpuId } | Select-Object -First 1
        if (-not $entry) { continue }
        $status = $entry.stockStatus
        if ([string]::IsNullOrWhiteSpace($status)) { continue }
        if ($status -eq 'Unavailable') { continue }

        $sortKey = 99
        if ($rank.ContainsKey($status)) { $sortKey = $rank[$status] }

        # Skip DCs that don't support network volumes.
        $supportsVolume = $VolumeSupportedDCs -contains $dc.id

        $obj = [PSCustomObject]@{
            Id              = [string]$dc.id
            Location        = [string]$dc.location
            Stock           = [string]$status
            SortKey         = [int]$sortKey
            SupportsVolume  = [bool]$supportsVolume
        }
        [void]$candidates.Add($obj)
    }

    $volumeCapable = @($candidates | Where-Object { $_.SupportsVolume })
    if ($volumeCapable.Count -eq 0) {
        Warn "No volume-capable datacenter is currently reporting stock for '$GpuId'."
        Warn "Run with -DataCenter <id> to override. Falling back to EU-RO-1."
        $DataCenter = 'EU-RO-1'
    } else {
        $sorted = @($volumeCapable | Sort-Object SortKey, Id)
        Log "Volume-capable candidate DCs (sorted High > Medium > Low):"
        foreach ($c in $sorted) {
            Log ("  - {0,-10}  loc={1,-15}  stock={2}" -f $c.Id, $c.Location, $c.Stock)
        }
        $DataCenter = [string]$sorted[0].Id
        Log "Picked: $DataCenter ($($sorted[0].Stock) stock)"
    }

    # Also note non-volume-capable but high-stock DCs for context
    $nonVolHighStock = @($candidates | Where-Object { -not $_.SupportsVolume -and $_.Stock -eq 'High' })
    if ($nonVolHighStock.Count -gt 0) {
        Log "FYI - these DCs have High stock but don't support network volumes:"
        foreach ($c in $nonVolHighStock) { Log ("  (skipped) {0}  stock={1}" -f $c.Id, $c.Stock) }
    }
}

# Sanity-check: $DataCenter must be a single id, not an array or space-joined string
$DataCenter = ([string]$DataCenter).Trim()
if ($DataCenter -match '\s' -or $DataCenter -match ',') {
    Die "Internal bug: \$DataCenter contains whitespace or a comma: '$DataCenter'. Aborting before passing to runpodctl. Please paste this output."
}
if (-not ($DataCenter -match '^[A-Za-z0-9\-]+$')) {
    Die "Internal bug: \$DataCenter looks malformed: '$DataCenter'. Aborting."
}
Log "Using DATA_CENTER_ID=$DataCenter"

# Now create the volume if we didn't already find one
if (-not $VolumeId) {
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

# Pod create with retry — RunPod stock fluctuates rapidly. Try up to 6 times
# with 30s backoff before giving up. Any non-stock error fails fast.
$PodId = $null
$podOut = $null
for ($attempt = 1; $attempt -le 6; $attempt++) {
    if ($attempt -gt 1) {
        Log "Retry attempt $attempt/6 after 30s backoff"
        Start-Sleep -Seconds 30
    }
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
        if ($pod.id) { $PodId = $pod.id; break }
    } catch {}

    # If it's a stock/availability error, retry. Anything else, fail fast.
    if ($podOut -match 'no longer any instances available' -or
        $podOut -match 'no instances available' -or
        $podOut -match 'capacity') {
        Warn "Stock unavailable in $DataCenter on attempt $attempt. Will retry."
        continue
    }
    Die "Pod create failed (attempt $attempt): $podOut"
}

if (-not $PodId) {
    Warn "Pod create failed after 6 attempts. The DC '$DataCenter' has no H100 stock right now."
    Warn "Options:"
    Warn "  1. Wait and re-run later."
    Warn "  2. Delete the network volume (runpodctl network-volume delete $VolumeId) and re-run; auto-pick may choose a DC with current stock."
    Warn "  3. Manually pick another volume-supported DC: .\scripts\deploy.ps1 -DataCenter <id> (after deleting volume)."
    Die "All retries exhausted: $podOut"
}

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
