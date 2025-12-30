# InvokeAI + ROCm 7.1.1 Setup Script for RX 9070 XT
# Run this script ONCE to set up the environment
# Everything is installed locally - NOTHING on C: drive

# ===========================================
# CONFIGURATION - Change these if needed
# ===========================================
$INVOKEAI_VERSION = "6.9.0"  # InvokeAI version to install
# ===========================================

$ErrorActionPreference = "Stop"
$PROJECT_ROOT = $PSScriptRoot

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "InvokeAI + ROCm 7.1.1 Setup" -ForegroundColor Cyan
Write-Host "Tested on AMD RX 9070 XT (RDNA4)" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Project folder: $PROJECT_ROOT" -ForegroundColor Gray
Write-Host ""

# Paths
$MINICONDA_PATH = "$PROJECT_ROOT\miniconda"
$CONDA_EXE = "$MINICONDA_PATH\Scripts\conda.exe"
$PYTHON_EXE = "$MINICONDA_PATH\envs\invokeai\python.exe"
$PIP_EXE = "$MINICONDA_PATH\envs\invokeai\Scripts\pip.exe"
$ENV_PATH = "$MINICONDA_PATH\envs\invokeai"

# Set environment variables to keep everything local
$env:PIP_CACHE_DIR = "$PROJECT_ROOT\.cache\pip"
$env:HF_HOME = "$PROJECT_ROOT\.cache\huggingface"
$env:TORCH_HOME = "$PROJECT_ROOT\.cache\torch"
$env:XDG_CACHE_HOME = "$PROJECT_ROOT\.cache"
$env:INVOKEAI_ROOT = "$PROJECT_ROOT\invokeai-data"
$env:CONDA_PKGS_DIRS = "$PROJECT_ROOT\.cache\conda\pkgs"

# Create directories
Write-Host "[1/10] Creating directories..." -ForegroundColor Green
$dirs = @(
    "$PROJECT_ROOT\.cache\pip",
    "$PROJECT_ROOT\.cache\huggingface",
    "$PROJECT_ROOT\.cache\torch",
    "$PROJECT_ROOT\.cache\conda\pkgs",
    "$PROJECT_ROOT\invokeai-data"
)
foreach ($dir in $dirs) {
    if (-not (Test-Path $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

# Download and install Miniconda locally
Write-Host "[2/10] Setting up Miniconda locally..." -ForegroundColor Green
if (-not (Test-Path $CONDA_EXE)) {
    $minicondaInstaller = "$PROJECT_ROOT\Miniconda3-latest-Windows-x86_64.exe"

    if (-not (Test-Path $minicondaInstaller)) {
        Write-Host "  Downloading Miniconda (this may take a few minutes)..." -ForegroundColor Yellow
        $minicondaUrl = "https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-x86_64.exe"
        Invoke-WebRequest -Uri $minicondaUrl -OutFile $minicondaInstaller -UseBasicParsing
    }

    Write-Host "  Installing Miniconda to project folder..." -ForegroundColor Yellow
    Start-Process -FilePath $minicondaInstaller -ArgumentList "/S", "/D=$MINICONDA_PATH" -Wait

    # Clean up installer
    Remove-Item $minicondaInstaller -Force
    Write-Host "  Miniconda installed successfully" -ForegroundColor Green
} else {
    Write-Host "  Miniconda already installed" -ForegroundColor Yellow
}

# Accept conda TOS (required for Anaconda channels)
Write-Host "[3/10] Accepting conda Terms of Service..." -ForegroundColor Green
& $CONDA_EXE tos accept --override-channels --channel https://repo.anaconda.com/pkgs/main 2>$null
& $CONDA_EXE tos accept --override-channels --channel https://repo.anaconda.com/pkgs/r 2>$null
& $CONDA_EXE tos accept --override-channels --channel https://repo.anaconda.com/pkgs/msys2 2>$null

# Create conda environment with Python 3.12
Write-Host "[4/10] Creating Python 3.12 environment..." -ForegroundColor Green
if (-not (Test-Path $ENV_PATH)) {
    & $CONDA_EXE create -p $ENV_PATH python=3.12 -y
    Write-Host "  Python 3.12 environment created" -ForegroundColor Green
} else {
    Write-Host "  Python environment already exists" -ForegroundColor Yellow
}

# Verify Python version
$pythonVersion = & $PYTHON_EXE --version 2>&1
Write-Host "  Python version: $pythonVersion" -ForegroundColor Cyan

# Install ROCm SDK packages (required for PyTorch)
Write-Host "[5/10] Installing ROCm 7.1.1 SDK packages (~3.5GB)..." -ForegroundColor Green
Write-Host "  This will take several minutes..." -ForegroundColor Yellow

$rocmCore = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/rocm_sdk_core-0.1.dev0-py3-none-win_amd64.whl"
$rocmDevel = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/rocm_sdk_devel-0.1.dev0-py3-none-win_amd64.whl"
$rocmLibs = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/rocm_sdk_libraries_custom-0.1.dev0-py3-none-win_amd64.whl"
$rocmMeta = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/rocm-0.1.dev0.tar.gz"

& $PIP_EXE install --no-cache-dir $rocmCore $rocmDevel $rocmLibs $rocmMeta

# Install ROCm PyTorch wheels
Write-Host "[6/10] Installing ROCm 7.1.1 PyTorch wheels (~725MB)..." -ForegroundColor Green

$torchWheel = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/torch-2.9.0+rocmsdk20251116-cp312-cp312-win_amd64.whl"
$torchaudioWheel = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/torchaudio-2.9.0+rocmsdk20251116-cp312-cp312-win_amd64.whl"
$torchvisionWheel = "https://repo.radeon.com/rocm/windows/rocm-rel-7.1.1/torchvision-0.24.0+rocmsdk20251116-cp312-cp312-win_amd64.whl"

& $PIP_EXE install --no-deps --cache-dir "$PROJECT_ROOT\.cache\pip" $torchWheel $torchaudioWheel $torchvisionWheel

# Install PyTorch dependencies (without the rocm meta package conflict)
Write-Host "[7/10] Installing PyTorch dependencies..." -ForegroundColor Green
& $PIP_EXE install --cache-dir "$PROJECT_ROOT\.cache\pip" filelock typing-extensions sympy networkx jinja2 fsspec pillow "numpy<2.0"

# Verify GPU detection
Write-Host "[8/10] Verifying GPU detection..." -ForegroundColor Green
$gpuCheck = & $PYTHON_EXE -c "import torch; print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'NO_GPU')" 2>&1

if ($gpuCheck -eq "NO_GPU" -or $gpuCheck -match "error") {
    Write-Host ""
    Write-Host "  WARNING: No AMD GPU detected!" -ForegroundColor Red
    Write-Host "  Make sure you have:" -ForegroundColor Yellow
    Write-Host "    1. AMD Driver 25.20.0.17 or newer installed" -ForegroundColor Yellow
    Write-Host "    2. ROCm components enabled in the driver" -ForegroundColor Yellow
    Write-Host "    3. AMD GPU properly installed" -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "  GPU detected: $gpuCheck" -ForegroundColor Cyan
}

# Install InvokeAI
Write-Host "[9/10] Installing InvokeAI..." -ForegroundColor Green
Write-Host "  This may take several minutes..." -ForegroundColor Yellow
& $PIP_EXE install --cache-dir "$PROJECT_ROOT\.cache\pip" "invokeai==$INVOKEAI_VERSION"

# Reinstall ROCm PyTorch (InvokeAI may have overwritten it)
Write-Host "  Ensuring ROCm PyTorch is active..." -ForegroundColor Yellow
& $PIP_EXE uninstall torch -y 2>$null
& $PIP_EXE install --no-deps --cache-dir "$PROJECT_ROOT\.cache\pip" $torchWheel

# Apply VAE speed fix for AMD ROCm
Write-Host "[10/10] Applying AMD ROCm VAE speed patch..." -ForegroundColor Green
$latentsToImagePath = "$ENV_PATH\Lib\site-packages\invokeai\app\invocations\latents_to_image.py"

if (Test-Path $latentsToImagePath) {
    $content = Get-Content $latentsToImagePath -Raw
    $patched = $false

    # Check if already patched
    if ($content -match "PATCHED.*AMD ROCm") {
        Write-Host "  VAE patch already applied" -ForegroundColor Yellow
    } else {
        # Patch 1: Change tile_size default from 0 to 512
        if ($content -match 'tile_size: int = InputField\(default=0,') {
            $content = $content -replace 'tile_size: int = InputField\(default=0,', 'tile_size: int = InputField(default=512,'
            $patched = $true
        }

        # Patch 2: Add cuDNN disable before VAE decode
        # Find the line "# clear memory as vae decode can request a lot" and add patch after TorchDevice.empty_cache()
        $searchPattern = "# clear memory as vae decode can request a lot`r?`n\s+TorchDevice\.empty_cache\(\)`r?`n`r?`n\s+with torch\.inference_mode"
        $replacementBlock = @"
# clear memory as vae decode can request a lot
            TorchDevice.empty_cache()

            # PATCHED: Disable cudnn/MIOpen for VAE decode on AMD ROCm (fixes extreme slowness)
            # See: https://github.com/comfyanonymous/ComfyUI/pull/10302
            # NOTE: We do NOT restore cudnn - leaving it disabled prevents MIOpen from
            # accumulating slow kernels during the session
            torch.backends.cudnn.enabled = False
            torch.backends.cudnn.benchmark = False

            with torch.inference_mode
"@
        if ($content -match $searchPattern) {
            $content = $content -replace $searchPattern, $replacementBlock
            $patched = $true
        }

        if ($patched) {
            Set-Content -Path $latentsToImagePath -Value $content -NoNewline
            Write-Host "  VAE patch applied successfully" -ForegroundColor Green
            Write-Host "  - tile_size default: 0 -> 512" -ForegroundColor Gray
            Write-Host "  - cuDNN/MIOpen disabled during VAE decode" -ForegroundColor Gray
        } else {
            Write-Host "  WARNING: Could not apply patch (file structure may have changed)" -ForegroundColor Red
            Write-Host "  You may need to manually patch latents_to_image.py" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "  WARNING: latents_to_image.py not found!" -ForegroundColor Red
    Write-Host "  Path: $latentsToImagePath" -ForegroundColor Gray
}

# Final verification
Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Verifying Installation..." -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green

$torchVer = & $PYTHON_EXE -c "import torch; print(torch.__version__)" 2>$null
$gpuName = & $PYTHON_EXE -c "import torch; print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'N/A')" 2>$null
$invokeCheck = & $PIP_EXE show invokeai 2>$null | Select-String "Version"

Write-Host "  PyTorch: $torchVer" -ForegroundColor Cyan
Write-Host "  GPU: $gpuName" -ForegroundColor Cyan
Write-Host "  InvokeAI: $invokeCheck" -ForegroundColor Cyan

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host "Setup Complete!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Directory structure:" -ForegroundColor Cyan
Write-Host "  $PROJECT_ROOT" -ForegroundColor White
Write-Host "  +-- miniconda\        (Python environment)" -ForegroundColor Gray
Write-Host "  +-- .cache\           (pip, huggingface, torch caches)" -ForegroundColor Gray
Write-Host "  +-- invokeai-data\    (models, outputs, configs)" -ForegroundColor Gray
Write-Host "  +-- run.ps1           (launch script)" -ForegroundColor Gray
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Cyan
Write-Host "  1. Run: .\run.ps1" -ForegroundColor White
Write-Host "  2. Open: http://localhost:9090" -ForegroundColor White
Write-Host ""
Write-Host "First run will prompt you to download models." -ForegroundColor Yellow
