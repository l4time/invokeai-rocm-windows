# InvokeAI + ROCm 7.1.1 for AMD GPUs (Windows)

Native Windows setup for InvokeAI with AMD ROCm 7.1.1 support.

## Features

- **Portable** - Uses Miniconda to install everything in the project folder (nothing on C: drive)
- **Automatic VAE fix** - Patches the ROCm VAE slowdown issue during setup
- **Self-contained** - All caches (pip, huggingface, torch) stored locally

## Tested On

- Windows 11
- AMD RX 9070 XT (16GB VRAM)
- AMD Driver 25.12.1 with ROCm components enabled

## Quick Start

```powershell
# First time setup (run once)
.\setup.ps1

# Launch InvokeAI
.\run.ps1
```

Then open http://localhost:9090

## Directory Structure

```
Invoke-AI-Docker\
├── miniconda\              # Python 3.12 environment
│   └── envs\invokeai\      # InvokeAI + ROCm packages
├── .cache\                 # Local caches
│   ├── pip\
│   ├── huggingface\
│   ├── miopen\
│   └── torch\
├── invokeai-data\          # InvokeAI data
│   ├── models\
│   ├── outputs\
│   ├── databases\
│   └── invokeai.yaml
├── setup.ps1               # One-time setup script
├── run.ps1                 # Launch script
└── README.md
```

## Installed Versions

- Python: 3.12
- PyTorch: 2.9.0+rocmsdk20251116
- ROCm SDK: 7.1.1
- InvokeAI: 6.9.0

## Configuration (invokeai.yaml)

```yaml
device_working_mem_gb: 8        # Working memory for VAE decode
force_tiled_decode: true        # Tiled VAE (required for 1024x1024 SDXL)
```

## ROCm VAE Performance Fix

ROCm 7.x on Windows has a known issue where VAE decode is extremely slow (30+ seconds). The root cause is unknown, but disabling cuDNN/MIOpen during VAE operations fixes it. The setup script automatically patches InvokeAI.

### What the Patch Does

Patches `latents_to_image.py` in InvokeAI:

```python
# Before VAE decode, disable cuDNN (MIOpen on AMD)
torch.backends.cudnn.enabled = False
torch.backends.cudnn.benchmark = False

# Change tile_size default from 0 to 512
tile_size: int = InputField(default=512, ...)
```

This forces PyTorch to use native convolutions instead of MIOpen, which fixes the slowdown.

Patch location: `miniconda\envs\invokeai\Lib\site-packages\invokeai\app\invocations\latents_to_image.py`

### Environment Variables (run.ps1)

```powershell
$env:MIOPEN_FIND_MODE = "FAST"
$env:PYTHONWARNINGS = "ignore::DeprecationWarning"
```

### Results

Tested with waiIllustriousSDXL_v160 at 1024x1024:

| Metric | Before Fix | After Fix |
|--------|------------|-----------|
| VAE decode | 30-35 seconds | ~5-6 seconds |
| Denoise (22 steps) | ~5 seconds | ~5 seconds |
| Total generation time | ~40 seconds | ~11 seconds |

### Reference

- [ComfyUI PR #10302](https://github.com/comfyanonymous/ComfyUI/pull/10302)
