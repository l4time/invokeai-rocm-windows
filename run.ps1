# InvokeAI + ROCm 7.1.1 Launch Script
# Run this script to start InvokeAI

$ErrorActionPreference = "SilentlyContinue"
$PROJECT_ROOT = $PSScriptRoot

Write-Host ""
Write-Host "  InvokeAI + ROCm 7.1.1" -ForegroundColor Cyan
Write-Host "  =====================" -ForegroundColor Cyan
Write-Host ""

# Paths
$MINICONDA_PATH = "$PROJECT_ROOT\miniconda"
$PYTHON_EXE = "$MINICONDA_PATH\envs\invokeai\python.exe"
$INVOKEAI_WEB = "$MINICONDA_PATH\envs\invokeai\Scripts\invokeai-web.exe"

# Check if environment exists
if (-not (Test-Path $PYTHON_EXE)) {
    Write-Host "  ERROR: Python environment not found!" -ForegroundColor Red
    Write-Host "  Please run setup.ps1 first." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Press any key to exit..."
    $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    exit 1
}

# Set environment variables to keep everything local
$env:PIP_CACHE_DIR = "$PROJECT_ROOT\.cache\pip"
$env:HF_HOME = "$PROJECT_ROOT\.cache\huggingface"
$env:TORCH_HOME = "$PROJECT_ROOT\.cache\torch"
$env:XDG_CACHE_HOME = "$PROJECT_ROOT\.cache"
$env:INVOKEAI_ROOT = "$PROJECT_ROOT\invokeai-data"

# Fix for ROCm 7 VAE speed issues - MIOpen has performance bugs
$env:MIOPEN_FIND_MODE = "FAST"

# Suppress Python deprecation warnings (noisy third-party libs)
$env:PYTHONWARNINGS = "ignore::DeprecationWarning"

# Suppress bitsandbytes ROCm warnings (not needed for basic generation)
$env:BITSANDBYTES_NOWELCOME = "1"
$env:BNB_CUDA_VERSION = ""

# Set MIOpen cache to local folder and clear it on start
$env:MIOPEN_USER_DB_PATH = "$PROJECT_ROOT\.cache\miopen\db"
$env:MIOPEN_CACHE_DIR = "$PROJECT_ROOT\.cache\miopen\cache"
if (Test-Path "$PROJECT_ROOT\.cache\miopen") {
    Remove-Item -Recurse -Force "$PROJECT_ROOT\.cache\miopen" -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Path "$PROJECT_ROOT\.cache\miopen\db" -Force | Out-Null
New-Item -ItemType Directory -Path "$PROJECT_ROOT\.cache\miopen\cache" -Force | Out-Null

# Clear InvokeAI Python cache (ensures patches are always loaded)
$cachePaths = @(
    "$PROJECT_ROOT\miniconda\envs\invokeai\Lib\site-packages\invokeai\app\invocations\__pycache__",
    "$PROJECT_ROOT\miniconda\envs\invokeai\Lib\site-packages\invokeai\app\util\__pycache__"
)
foreach ($cachePath in $cachePaths) {
    if (Test-Path $cachePath) {
        Remove-Item -Recurse -Force $cachePath -ErrorAction SilentlyContinue
    }
}

# Check GPU (suppress warnings)
Write-Host "  Checking GPU..." -ForegroundColor Gray
$gpuCheck = & $PYTHON_EXE -c "import torch; print(torch.cuda.get_device_name(0) if torch.cuda.is_available() else 'CPU')" 2>$null
if ($gpuCheck) {
    # Clean up the output (remove warning lines)
    $gpuName = ($gpuCheck -split "`n" | Where-Object { $_ -notmatch "Warning|warning|ERROR" } | Select-Object -Last 1).Trim()
    if ($gpuName) {
        Write-Host "  GPU: $gpuName" -ForegroundColor Green
    } else {
        Write-Host "  GPU: Detected (name unavailable)" -ForegroundColor Yellow
    }
} else {
    Write-Host "  GPU: Not detected" -ForegroundColor Yellow
}
Write-Host ""

# Launch InvokeAI
Write-Host "  Starting web interface..." -ForegroundColor Gray
Write-Host ""
Write-Host "  URL: http://localhost:9090" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Press Ctrl+C to stop" -ForegroundColor DarkGray
Write-Host ""

# Run InvokeAI (output to console and log file)
& $INVOKEAI_WEB 2>&1 | Tee-Object -FilePath "$PROJECT_ROOT\invokeai.log"

# After exit
Write-Host ""
Write-Host "  InvokeAI stopped. Log saved to invokeai.log" -ForegroundColor Gray
Write-Host ""
Write-Host "Press any key to exit..."
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
