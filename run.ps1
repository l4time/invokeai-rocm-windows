# Launch InvokeAI 6.14 with ROCm 10 on Windows.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
$EnvironmentPath = Join-Path $ProjectRoot 'env'
$PythonExe = Join-Path $EnvironmentPath 'python.exe'
$InvokeAIWeb = Join-Path $EnvironmentPath 'Scripts\invokeai-web.exe'
$CacheRoot = Join-Path $ProjectRoot '.cache'

if (-not (Test-Path -LiteralPath $PythonExe) -or -not (Test-Path -LiteralPath $InvokeAIWeb)) {
    throw 'The ROCm 10 environment is missing. Run .\setup.ps1 first.'
}

$env:PIP_CACHE_DIR = Join-Path $CacheRoot 'pip'
$env:HF_HOME = Join-Path $CacheRoot 'huggingface'
$env:TORCH_HOME = Join-Path $CacheRoot 'torch'
$env:XDG_CACHE_HOME = $CacheRoot
$env:INVOKEAI_ROOT = Join-Path $ProjectRoot 'invokeai-data'
$env:MIOPEN_FIND_MODE = 'FAST'
$env:MIOPEN_USER_DB_PATH = Join-Path $CacheRoot 'miopen\db'
$env:MIOPEN_CACHE_DIR = Join-Path $CacheRoot 'miopen\cache'
$env:PATH = "$EnvironmentPath;$(Join-Path $EnvironmentPath 'Scripts');$env:PATH"

foreach ($directory in @(
    $env:INVOKEAI_ROOT,
    $env:MIOPEN_USER_DB_PATH,
    $env:MIOPEN_CACHE_DIR
)) {
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
}

$runtimeProbe = @'
from importlib.metadata import version
import torch

assert version('InvokeAI') == '6.14.0'
assert torch.__version__ == '2.13.0+rocm10.0.0'
assert torch.cuda.is_available(), 'ROCm GPU is unavailable'
print(
    'InvokeAI '
    + version('InvokeAI')
    + ' | PyTorch '
    + torch.__version__
    + ' | '
    + torch.cuda.get_device_name(0)
)
'@
$runtime = & $PythonExe -c $runtimeProbe
if ($LASTEXITCODE -ne 0) {
    throw 'The ROCm 10 runtime preflight failed.'
}

Write-Host "`n$runtime" -ForegroundColor Cyan
Write-Host 'http://localhost:9090' -ForegroundColor Cyan
Write-Host 'Press Ctrl+C to stop.' -ForegroundColor DarkGray

$ErrorActionPreference = 'Continue'
& $InvokeAIWeb 2>&1 |
    ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        }
        else {
            $_
        }
    } |
    Tee-Object -FilePath (Join-Path $ProjectRoot 'invokeai.log')
exit $LASTEXITCODE
