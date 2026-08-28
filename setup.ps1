# InvokeAI 6.14 + ROCm 10 setup for supported AMD GPUs on Windows.
# The Python runtime, ROCm packages, caches, models, and outputs stay under
# this project directory. Windows and the AMD display driver remain system-wide.

[CmdletBinding()]
param(
    [ValidateSet('Auto', 'gfx1201', 'gfx1032')]
    [string] $GpuProfile = 'Auto'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$InvokeAIVersion = '6.14.0'
$TorchVersion = '2.13.0+rocm10.0.0'
$TorchvisionVersion = '0.28.0+rocm10.0.0'
$BitsAndBytesVersion = '0.50.2'
$RocmSdkVersion = '10.0.0'
$ComfyKitchenVersion = '0.2.31'
$ComfyKitchenCommit = '7490d8787ebd8bff49a0f59d8a40875cf2c98c1d'
$AmdIndexUrl = 'https://stable.repo.amd.com/rocm/whl-next/'

$ProjectRoot = $PSScriptRoot
$MinicondaPath = Join-Path $ProjectRoot 'miniconda'
$CondaExe = Join-Path $MinicondaPath 'Scripts\conda.exe'
$EnvironmentPath = Join-Path $ProjectRoot 'env'
$PythonExe = Join-Path $EnvironmentPath 'python.exe'
$InvokeAIWeb = Join-Path $EnvironmentPath 'Scripts\invokeai-web.exe'
$DataRoot = Join-Path $ProjectRoot 'invokeai-data'
$ConfigPath = Join-Path $DataRoot 'invokeai.yaml'
$CacheRoot = Join-Path $ProjectRoot '.cache'
$ManifestRoot = Join-Path $ProjectRoot 'install-manifests'
$SourcesRoot = Join-Path $CacheRoot 'sources'
$ComfyKitchenSource = Join-Path $SourcesRoot 'comfy-kitchen'
$ComfyKitchenSourceMarker = Join-Path $ComfyKitchenSource '.invokeai-rocm-source-commit'
$PatchesRoot = Join-Path $ProjectRoot 'patches'
$SitePackagesPath = Join-Path $EnvironmentPath 'Lib\site-packages'
$RocmBinPath = Join-Path $SitePackagesPath '_rocm_sdk_core\bin'
$RocmLlvmBinPath = Join-Path $SitePackagesPath '_rocm_sdk_core\lib\llvm\bin'

. (Join-Path $ProjectRoot 'scripts\gpu-profiles.ps1')
$RequestedGpuProfile = $GpuProfile
if ($GpuProfile -eq 'Auto') {
    $windowsAdapterNames = @(
        Get-CimInstance Win32_VideoController -ErrorAction Stop |
            ForEach-Object { [string] $_.Name } |
            Where-Object { $_ }
    )
    $GpuProfile = Resolve-InvokeAIGpuProfileId -AdapterNames $windowsAdapterNames
}
$SelectedGpuProfile = Get-InvokeAIGpuProfile -Id $GpuProfile
$ProfileVersions = @{
    invokeai = $InvokeAIVersion
    torch = $TorchVersion
    torchvision = $TorchvisionVersion
    bitsandbytes = $BitsAndBytesVersion
    rocm = $RocmSdkVersion
}

function Invoke-Checked {
    param(
        [Parameter(Mandatory)]
        [string] $FilePath,
        [Parameter()]
        [string[]] $ArgumentList = @()
    )

    & $FilePath @ArgumentList
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed with exit code $LASTEXITCODE`: $FilePath $($ArgumentList -join ' ')"
    }
}

function Write-Step {
    param([string] $Message)
    Write-Host "`n==> $Message" -ForegroundColor Green
}

function Set-Utf8NoBom {
    param(
        [Parameter(Mandatory)]
        [string] $Path,
        [Parameter(Mandatory)]
        [string] $Value
    )

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Value, $utf8NoBom)
}

Write-Host 'InvokeAI 6.14 + ROCm 10 for Windows' -ForegroundColor Cyan
Write-Host "Project: $ProjectRoot" -ForegroundColor DarkGray
Write-Host "GPU profile: $($SelectedGpuProfile.DisplayName) ($GpuProfile, $($SelectedGpuProfile.VramGB) GB)" -ForegroundColor DarkGray
if ($RequestedGpuProfile -eq 'Auto') {
    Write-Host 'GPU profile was detected automatically by Windows.' -ForegroundColor DarkGray
}

$existingProfileManifest = Read-InvokeAIGpuProfileManifest `
    -EnvironmentPath $EnvironmentPath `
    -AllowMissing
if (
    $null -ne $existingProfileManifest -and
    [string] $existingProfileManifest.gpu_profile -ne $GpuProfile
) {
    throw (
        "This environment contains the '$($existingProfileManifest.gpu_profile)' GPU profile. " +
        "It cannot be changed in place to '$GpuProfile'. Rename the 'env' directory and rerun setup."
    )
}

foreach ($directory in @(
    $DataRoot,
    $ManifestRoot,
    (Join-Path $CacheRoot 'pip'),
    (Join-Path $CacheRoot 'huggingface'),
    (Join-Path $CacheRoot 'torch'),
    (Join-Path $CacheRoot 'conda\pkgs'),
    $SourcesRoot,
    (Join-Path $CacheRoot 'miopen\db'),
    (Join-Path $CacheRoot 'miopen\cache')
)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$env:PIP_CACHE_DIR = Join-Path $CacheRoot 'pip'
$env:HF_HOME = Join-Path $CacheRoot 'huggingface'
$env:TORCH_HOME = Join-Path $CacheRoot 'torch'
$env:XDG_CACHE_HOME = $CacheRoot
$env:CONDA_PKGS_DIRS = Join-Path $CacheRoot 'conda\pkgs'
$env:INVOKEAI_ROOT = $DataRoot
$env:PATH = (
    "$EnvironmentPath;$EnvironmentPath\Scripts;" +
    "$RocmBinPath;$RocmLlvmBinPath;$env:PATH"
)

Write-Step 'Preparing project-local Miniconda'
if (-not (Test-Path -LiteralPath $CondaExe)) {
    $installerPath = Join-Path $ProjectRoot 'Miniconda3-latest-Windows-x86_64.exe'
    $installerUrl = 'https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe'

    Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing
    try {
        $installer = Start-Process `
            -FilePath $installerPath `
            -ArgumentList @('/S', "/D=$MinicondaPath") `
            -Wait `
            -PassThru
        if ($installer.ExitCode -ne 0) {
            throw "Miniconda installer failed with exit code $($installer.ExitCode)"
        }
    }
    finally {
        if (Test-Path -LiteralPath $installerPath) {
            Remove-Item -LiteralPath $installerPath -Force
        }
    }
}

foreach ($channel in @(
    'https://repo.anaconda.com/pkgs/main',
    'https://repo.anaconda.com/pkgs/r',
    'https://repo.anaconda.com/pkgs/msys2'
)) {
    & $CondaExe tos accept --override-channels --channel $channel 2>$null
}

Write-Step "Creating the short-path Python 3.12 environment at '$EnvironmentPath'"
if (-not (Test-Path -LiteralPath $PythonExe)) {
    Invoke-Checked $CondaExe @('create', '-p', $EnvironmentPath, 'python=3.12', '-y')
}

$pythonVersion = & $PythonExe --version
if ($LASTEXITCODE -ne 0 -or $pythonVersion -notmatch '^Python 3\.12\.') {
    throw "Expected Python 3.12, found: $pythonVersion"
}
Write-Host "Python: $pythonVersion" -ForegroundColor Cyan

$installedDeviceProbe = @'
from importlib.metadata import distributions
import re

architectures = set()
for distribution in distributions():
    name = (distribution.metadata.get("Name") or "").lower()
    match = re.search(r"device-(gfx[0-9a-f]+)$", name)
    if match:
        architectures.add(match.group(1))
print(",".join(sorted(architectures)))
'@
$installedDeviceProbePath = Join-Path $ManifestRoot 'installed-device-packages.py'
$installedDeviceProbe | Set-Content -LiteralPath $installedDeviceProbePath -Encoding utf8
$installedDeviceArchitectures = & $PythonExe $installedDeviceProbePath
if ($LASTEXITCODE -ne 0) {
    throw 'Could not inspect existing ROCm device packages.'
}
foreach ($installedArchitecture in @($installedDeviceArchitectures -split ',')) {
    if ($installedArchitecture -and $installedArchitecture -ne $GpuProfile) {
        throw (
            "The environment contains ROCm packages for '$installedArchitecture', not '$GpuProfile'. " +
            "Rename the 'env' directory and rerun setup; mixed GPU packages are not supported."
        )
    }
}

Write-InvokeAIGpuProfileManifest `
    -EnvironmentPath $EnvironmentPath `
    -Profile $SelectedGpuProfile `
    -Status 'installing' `
    -Versions $ProfileVersions

Write-Step 'Updating Python packaging tools'
Invoke-Checked $PythonExe @('-m', 'pip', 'install', '--quiet', '--upgrade', 'pip', 'setuptools', 'wheel')

Write-Step "Installing ROCm 10 PyTorch and $GpuProfile device kernels"
Invoke-Checked $PythonExe @(
    '-m', 'pip', 'install',
    '--quiet',
    '--index-url', $AmdIndexUrl,
    "torch[device-$GpuProfile]==$TorchVersion",
    "torchvision[device-$GpuProfile]==$TorchvisionVersion"
)

Remove-Item Env:HIP_VISIBLE_DEVICES -ErrorAction SilentlyContinue
$gpuInventoryProbe = @'
import json
import torch

print(json.dumps([
    {"index": index, "name": torch.cuda.get_device_name(index)}
    for index in range(torch.cuda.device_count())
]))
'@
$gpuInventoryProbePath = Join-Path $ManifestRoot 'gpu-inventory.py'
$gpuInventoryProbe | Set-Content -LiteralPath $gpuInventoryProbePath -Encoding utf8
$gpuInventoryJson = (& $PythonExe $gpuInventoryProbePath) -join ''
if ($LASTEXITCODE -ne 0) {
    throw 'Could not enumerate AMD GPUs through PyTorch.'
}
$gpuInventory = @($gpuInventoryJson | ConvertFrom-Json)
$selectedGpuDevice = Select-InvokeAIGpuDevice `
    -Profile $SelectedGpuProfile `
    -Devices $gpuInventory
$SelectedGpuDeviceIndex = [int] $selectedGpuDevice.index
$env:HIP_VISIBLE_DEVICES = [string] $SelectedGpuDeviceIndex
Write-Host (
    "Selected GPU [$SelectedGpuDeviceIndex]: $($selectedGpuDevice.name)"
) -ForegroundColor Cyan

Write-Step 'Running the ROCm GPU preflight'
foreach ($toolPath in @(
    (Join-Path $RocmBinPath 'hipInfo.exe'),
    (Join-Path $RocmLlvmBinPath 'amdgpu-arch.exe')
)) {
    if (-not (Test-Path -LiteralPath $toolPath)) {
        throw "The ROCm device tools are incomplete; missing: $toolPath"
    }
}

$detectedArchitectures = @(
    & (Join-Path $RocmLlvmBinPath 'amdgpu-arch.exe') |
        ForEach-Object { ([string] $_).Trim() } |
        Where-Object { $_ }
)
if ($LASTEXITCODE -ne 0 -or $GpuProfile -notin $detectedArchitectures) {
    throw (
        "Selected GPU profile '$GpuProfile', but amdgpu-arch detected: " +
        "$($detectedArchitectures -join ', ')"
    )
}

$gpuProbe = @"
import json
import torch
import torchvision

expected_torch = "2.13.0+rocm10.0.0"
expected_torchvision = "0.28.0+rocm10.0.0"
expected_name = "$($SelectedGpuProfile.ExpectedNamePattern)"
assert torch.__version__ == expected_torch, (torch.__version__, expected_torch)
assert torchvision.__version__ == expected_torchvision, (torchvision.__version__, expected_torchvision)
assert torch.cuda.is_available(), "ROCm GPU is not available through torch.cuda"
name = torch.cuda.get_device_name(0)
assert expected_name.lower() in name.lower(), (name, expected_name)

device = torch.device("cuda:0")
layer = torch.nn.Conv2d(32, 32, 3, padding=1, bias=False).to(device=device, dtype=torch.float16)
value = torch.randn((2, 32, 128, 128), device=device, dtype=torch.float16)
result = layer(value)
torch.cuda.synchronize()
assert bool(torch.isfinite(result).all().item())

print(json.dumps({
    "torch": torch.__version__,
    "torchvision": torchvision.__version__,
    "hip": torch.version.hip,
    "device": name,
    "device_capability": list(torch.cuda.get_device_capability(0)),
    "max_memory_allocated_bytes": torch.cuda.max_memory_allocated(),
}, indent=2))
"@
$gpuProbePath = Join-Path $ManifestRoot 'gpu-preflight.py'
$gpuProbe | Set-Content -LiteralPath $gpuProbePath -Encoding utf8
Invoke-Checked $PythonExe @($gpuProbePath)

Write-Step "Auditing InvokeAI $InvokeAIVersion dependency resolution"
$pipReport = Join-Path $ManifestRoot 'invokeai-pip-dry-run.json'
$constraintsPath = Join-Path $ManifestRoot 'rocm-constraints.txt'
@(
    "torch==$TorchVersion"
    "torchvision==$TorchvisionVersion"
    "bitsandbytes==$BitsAndBytesVersion"
) | Set-Content -LiteralPath $constraintsPath -Encoding ascii
Invoke-Checked $PythonExe @(
    '-m', 'pip', 'install',
    '--quiet',
    '--dry-run',
    '--report', $pipReport,
    '--constraint', $constraintsPath,
    "InvokeAI==$InvokeAIVersion",
    "bitsandbytes==$BitsAndBytesVersion"
)

$report = Get-Content -LiteralPath $pipReport -Raw | ConvertFrom-Json
foreach ($plannedInstall in @($report.install)) {
    $packageName = [string] $plannedInstall.metadata.name
    if ($packageName -in @('torch', 'torchvision')) {
        $plannedVersion = [string] $plannedInstall.metadata.version
        $plannedUrl = [string] $plannedInstall.download_info.url
        $expectedVersion = if ($packageName -eq 'torch') { $TorchVersion } else { $TorchvisionVersion }
        if ($plannedVersion -ne $expectedVersion -or $plannedUrl -notlike "$AmdIndexUrl*") {
            throw "InvokeAI would replace AMD $packageName with $plannedVersion from $plannedUrl"
        }
    }
}

Write-Step "Installing InvokeAI $InvokeAIVersion from PyPI"
Invoke-Checked $PythonExe @(
    '-m', 'pip', 'install',
    '--quiet',
    '--constraint', $constraintsPath,
    "InvokeAI==$InvokeAIVersion",
    "bitsandbytes==$BitsAndBytesVersion"
)
Invoke-Checked $PythonExe @(
    '-c',
    "import bitsandbytes, torch; from bitsandbytes.cuda_specs import get_rocm_gpu_arch; assert bitsandbytes.__version__ == '$BitsAndBytesVersion'; assert get_rocm_gpu_arch() == '$GpuProfile', get_rocm_gpu_arch(); assert '$($SelectedGpuProfile.ExpectedNamePattern)'.lower() in torch.cuda.get_device_name(0).lower(); print('bitsandbytes', bitsandbytes.__version__, '| architecture', get_rocm_gpu_arch())"
)

if ($SelectedGpuProfile.SupportsKrea2ConvRot) {
Write-Step 'Preparing native ConvRot INT4 kernels for gfx1201'
Invoke-Checked $PythonExe @(
    '-m', 'pip', 'install',
    '--quiet',
    '--index-url', $AmdIndexUrl,
    "rocm-sdk-devel==$RocmSdkVersion"
)
Invoke-Checked $PythonExe @('-m', 'rocm_sdk', 'init')
Invoke-Checked $PythonExe @(
    '-m', 'pip', 'install',
    '--quiet',
    'cmake==4.4.2',
    'ninja==1.13.0',
    'nanobind==3.0.0'
)

$comfyKitchenProbe = @"
from importlib.metadata import version
from comfy_kitchen.backends import hip
assert version("comfy-kitchen") == "$ComfyKitchenVersion"
assert hip.is_available()
assert hip.has_wmma()
"@
$comfyKitchenProbePath = Join-Path $ManifestRoot 'comfy-kitchen-readiness.py'
$comfyKitchenProbe | Set-Content -LiteralPath $comfyKitchenProbePath -Encoding utf8
$previousErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'SilentlyContinue'
& $PythonExe $comfyKitchenProbePath *> $null
$comfyKitchenReady = $LASTEXITCODE -eq 0
$ErrorActionPreference = $previousErrorActionPreference

if (-not $comfyKitchenReady) {
    $cachedSourceCommit = if (Test-Path -LiteralPath $ComfyKitchenSourceMarker) {
        (Get-Content -LiteralPath $ComfyKitchenSourceMarker -Raw).Trim()
    }
    else {
        ''
    }
    if (
        -not (Test-Path -LiteralPath (Join-Path $ComfyKitchenSource 'setup.py')) -or
        $cachedSourceCommit -ne $ComfyKitchenCommit
    ) {
        $sourceArchive = Join-Path $SourcesRoot "comfy-kitchen-$ComfyKitchenCommit.zip"
        $expandedSource = Join-Path $SourcesRoot "comfy-kitchen-$ComfyKitchenCommit"
        if (Test-Path -LiteralPath $ComfyKitchenSource) {
            Remove-Item -LiteralPath $ComfyKitchenSource -Recurse -Force
        }
        if (-not (Test-Path -LiteralPath $sourceArchive)) {
            Invoke-WebRequest `
                -Uri "https://github.com/Comfy-Org/comfy-kitchen/archive/$ComfyKitchenCommit.zip" `
                -OutFile $sourceArchive `
                -UseBasicParsing
        }
        if (Test-Path -LiteralPath $expandedSource) {
            Remove-Item -LiteralPath $expandedSource -Recurse -Force
        }
        Expand-Archive -LiteralPath $sourceArchive -DestinationPath $SourcesRoot -Force
        Move-Item -LiteralPath $expandedSource -Destination $ComfyKitchenSource
        $ComfyKitchenCommit |
            Set-Content -LiteralPath $ComfyKitchenSourceMarker -Encoding ascii
    }

    Invoke-Checked $PythonExe @(
        (Join-Path $PatchesRoot 'patch_comfy_kitchen.py'),
        '--source', $ComfyKitchenSource,
        '--site-packages', $SitePackagesPath
    )

    $env:COMFY_KITCHEN_BUILD_HIP = '1'
    $env:COMFY_HIP_ARCHS = 'gfx1201'
    Invoke-Checked $PythonExe @(
        '-m', 'pip', 'install',
        '--quiet',
        '--force-reinstall',
        '--no-build-isolation',
        '--no-deps',
        $ComfyKitchenSource
    )
}
else {
    Write-Host 'Native comfy-kitchen gfx1201 backend already works; rebuild skipped.' -ForegroundColor DarkGray
}

$convRotProbe = @'
import torch
import torch.nn.functional as functional
from comfy_kitchen.backends import hip
from comfy_kitchen.tensor import QuantizedTensor

assert hip.is_available(), "comfy-kitchen HIP backend is unavailable"
assert hip.has_wmma(), "gfx1201 matrix cores were not detected"
x = torch.randn((64, 256), device="cuda", dtype=torch.bfloat16)
w = torch.randn((128, 256), device="cuda", dtype=torch.bfloat16)
packed = QuantizedTensor.from_float(w, "TensorCoreConvRotW4A4Layout")
result = functional.linear(x, packed)
torch.cuda.synchronize()
assert result.shape == (64, 128)
assert bool(torch.isfinite(result).all().item())
print("Native ConvRot INT4 gfx1201 kernel: OK")
'@
$convRotProbePath = Join-Path $ManifestRoot 'convrot-preflight.py'
$convRotProbe | Set-Content -LiteralPath $convRotProbePath -Encoding utf8
Invoke-Checked $PythonExe @($convRotProbePath)

Write-Step 'Applying the InvokeAI 6.14 Krea 2 INT4 compatibility patch'
Invoke-Checked $PythonExe @(
    (Join-Path $PatchesRoot 'patch_invokeai.py'),
    '--site-packages', $SitePackagesPath
)
}
else {
    Write-Host (
        "Skipping Krea 2 ConvRot native kernels for $($SelectedGpuProfile.DisplayName). " +
        'Standard InvokeAI models remain available.'
    ) -ForegroundColor DarkGray
}

Write-Step "Applying settings for $($SelectedGpuProfile.DisplayName)"
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $invokeAIConfig = @"
# Internal metadata - do not edit:
schema_version: 4.0.3

# device_working_mem_gb is intentionally omitted to use the 3 GB default.
force_tiled_decode: true
"@
    if ($SelectedGpuProfile.Id -eq 'gfx1201') {
        $invokeAIConfig = $invokeAIConfig.TrimEnd() + "`r`nmax_cache_ram_gb: 16`r`n"
    }
    Set-Utf8NoBom -Path $ConfigPath -Value ($invokeAIConfig.TrimEnd() + "`r`n")
}
else {
    $configBackupPath = "$ConfigPath.pre-rocm-profile.bak"
    if (-not (Test-Path -LiteralPath $configBackupPath)) {
        Copy-Item -LiteralPath $ConfigPath -Destination $configBackupPath
    }
    $invokeAIConfig = Get-Content -LiteralPath $ConfigPath -Raw
    $invokeAIConfig = [regex]::Replace(
        $invokeAIConfig,
        '(?m)^\s*device_working_mem_gb\s*:.*(?:\r?\n)?',
        ''
    )
    if ($SelectedGpuProfile.Id -eq 'gfx1201') {
        if ($invokeAIConfig -match '(?m)^\s*max_cache_ram_gb\s*:') {
            $invokeAIConfig = [regex]::Replace(
                $invokeAIConfig,
                '(?m)^\s*max_cache_ram_gb\s*:.*$',
                'max_cache_ram_gb: 16'
            )
        }
        else {
            $invokeAIConfig = $invokeAIConfig.TrimEnd() + "`r`n`r`nmax_cache_ram_gb: 16`r`n"
        }
    }
    if ($invokeAIConfig -match '(?m)^\s*force_tiled_decode\s*:') {
        $invokeAIConfig = [regex]::Replace(
            $invokeAIConfig,
            '(?m)^\s*force_tiled_decode\s*:.*$',
            'force_tiled_decode: true'
        )
    }
    else {
        $invokeAIConfig = $invokeAIConfig.TrimEnd() + "`r`nforce_tiled_decode: true`r`n"
    }
    Set-Utf8NoBom -Path $ConfigPath -Value ($invokeAIConfig.TrimEnd() + "`r`n")
}

Write-Step 'Verifying the complete environment'
Invoke-Checked $PythonExe @('-m', 'pip', 'check')
Invoke-Checked $PythonExe @(
    '-c',
    "from importlib.metadata import version; import bitsandbytes, torch, torchvision; from bitsandbytes.cuda_specs import get_rocm_gpu_arch; assert version('InvokeAI') == '$InvokeAIVersion'; assert bitsandbytes.__version__ == '$BitsAndBytesVersion'; assert torch.__version__ == '$TorchVersion'; assert torchvision.__version__ == '$TorchvisionVersion'; assert get_rocm_gpu_arch() == '$GpuProfile'; assert '$($SelectedGpuProfile.ExpectedNamePattern)'.lower() in torch.cuda.get_device_name(0).lower(); print('InvokeAI', version('InvokeAI')); print('PyTorch', torch.__version__); print('Torchvision', torchvision.__version__); print('bitsandbytes', bitsandbytes.__version__); print('GPU', torch.cuda.get_device_name(0), '|', get_rocm_gpu_arch())"
)
if ($SelectedGpuProfile.SupportsKrea2ConvRot) {
    Invoke-Checked $PythonExe @(
        '-c',
        "from importlib.metadata import version; from comfy_kitchen.backends import hip; assert version('comfy-kitchen') == '$ComfyKitchenVersion'; assert hip.is_available() and hip.has_wmma(); print('Comfy Kitchen', version('comfy-kitchen'), '| native ConvRot ready')"
    )
}

& $PythonExe -m pip freeze |
    Set-Content -LiteralPath (Join-Path $ManifestRoot 'pip-freeze.txt') -Encoding utf8

if (-not (Test-Path -LiteralPath $InvokeAIWeb)) {
    throw "InvokeAI launcher was not installed at $InvokeAIWeb"
}

Write-InvokeAIGpuProfileManifest `
    -EnvironmentPath $EnvironmentPath `
    -Profile $SelectedGpuProfile `
    -Status 'complete' `
    -Versions $ProfileVersions `
    -DeviceIndex $SelectedGpuDeviceIndex

Write-Host "`nSetup complete." -ForegroundColor Green
Write-Host "Run .\run.ps1 and open http://localhost:9090" -ForegroundColor Cyan
