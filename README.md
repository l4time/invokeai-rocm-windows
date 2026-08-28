# InvokeAI + ROCm 10 for AMD GPUs on Windows

Native Windows setup using AMD's official ROCm/TheRock packages. It supports
the Radeon RX 9070 XT (`gfx1201`, 16 GB) and RX 6600 XT (`gfx1032`, 8 GB).

## Versions

- InvokeAI 6.14.0
- PyTorch 2.13.0+rocm10.0.0
- Torchvision 0.28.0+rocm10.0.0
- ROCm/TheRock 10.0
- Comfy Kitchen 0.2.31, native HIP build for `gfx1201` only
- Python 3.12

Python 3.12 is the tested, pinned runtime. InvokeAI 6.14 supports Python 3.11
and 3.12, and AMD provides matching ROCm 10 Windows wheels for both.

## Quick start

Clone or extract the project to a short path such as
`D:\AI\invokeai-rocm-windows`, then run:

```powershell
# RX 9070 XT
.\setup.ps1
.\run.ps1

# RX 6600 XT
.\setup.ps1 -GpuProfile gfx1032
.\run.ps1
```

Open <http://localhost:9090>.

The setup keeps Python, packages, caches, models, and outputs inside the project.
It installs the ROCm package matching the selected GPU and prevents InvokeAI
from replacing the AMD PyTorch build. If an AMD integrated GPU is also present,
it selects the named Radeon card explicitly. It is safe to rerun and does not
delete models, images, or the InvokeAI database.

This setup adds tested INT4 support for the RedCraft Krea 2 ConvRot model on the
RX 9070 XT. It is not enabled on the RX 6600 XT: that card is RDNA 2, uses a
different kernel target, and has 8 GB VRAM. Stock InvokeAI 6.14 does not support
this model format.

## Optional tested models

Each model installer starts InvokeAI if needed, downloads the complete tested
model set, and is safe to rerun:

```powershell
.\install-anima.ps1
.\install-krea2.ps1
```

The Anima script applies Turbo v1.1 defaults: ER-SDE, CFG 1, 8 steps, and
1024×1024. The Krea 2 script installs the RedCraft INT4 ConvRot checkpoint with
its FP8 encoder and applies Euler, CFG 1, 8 steps, and 1024×1024; the Krea
workflow uses its Simple noise schedule. The Krea 2 installer requires the
`gfx1201` RX 9070 XT profile and checks for 16 GB VRAM before downloading.

## Measured RX 9070 XT performance

### ROCm 7 stack → ROCm 10 stack

The same Wai Illustrious SDXL generation used 1024×1024, 22 steps, DPM++ 3M
Karras, CFG 7.5, and batch size 1.

| Metric | InvokeAI 6.9 + ROCm 7.1 | InvokeAI 6.14 + ROCm 10 | Improvement |
|---|---:|---:|---:|
| First image after starting InvokeAI | 35.17 s | 20.20 s | 42.6% lower latency |
| Sampler, model loaded | 4.53 it/s | 4.89 it/s | 7.9% faster |

**The complete ROCm 10 stack is 1.74× faster on the first image. Raw denoising
throughput is 1.08× faster.**

This is the user-visible improvement from upgrading the complete repository.
It includes the newer InvokeAI version, launcher, and settings as well as ROCm,
so it should not be read as a ROCm-only microbenchmark.

### Current model speed

| Model | Resolution / steps | Sampler | Model loaded | First image |
|---|---:|---:|---:|---:|
| Wai Illustrious SDXL | 1024² / 22 | 4.89 it/s | 6.04 s median | 20.20 s |
| RedCraft Krea 2 INT4 | 1024² / 8 | 1.05 it/s | 8.73 s median | 41.21 s median |
| Anima Turbo v1.1 | 1024² / 8 | 3.76 it/s | 3.02 s median | 14.64 s median |

Sampler rates are batch size 1. Loaded-model timing remained stable across 12
consecutive images. Compare `it/s` only for the same model and settings.

The RedCraft test used the
[30 Krea 2 INT4 ConvRot checkpoint](https://civitai.com/models/958009?modelVersionId=3139241)
with a Qwen3-VL FP8 encoder: Euler, Simple, CFG 1, 8 steps, and 1024×1024.

The Anima test used
[Turbo v1.1](https://civitai.com/models/2458426?modelVersionId=3263843)
with its native Qwen3 0.6B encoder and VAE: ER-SDE, CFG 1, 8 steps, 1024×1024,
and the model page's prompt prefix. The first run after install took 38.14
seconds while one-time runtime caches were created.

## Recommended InvokeAI settings

RX 9070 XT:

```yaml
max_cache_ram_gb: 16
force_tiled_decode: true
```

Leave `device_working_mem_gb` unset to use InvokeAI's 3 GB default. The old
8 GB reservation reduced the usable model cache. For RedCraft, automatic RAM
cache sizing caused repeated model reloads, while 16 GB of system-RAM cache kept
the working set resident. Tiled decode was also faster than untiled decode.

The RX 6600 XT profile keeps cache sizing automatic, leaves the 3 GB working
memory default unchanged, and enables tiled decode for its 8 GB VRAM limit.

## Benchmarking

Generate one image in the UI, note its queue item ID, then clone its graph:

```powershell
# Full generations with a different positive prompt each time
.\env\python.exe .\benchmark.py `
  --source-item-id 1 `
  --warmups 1 `
  --runs 12 `
  --variation prompt `
  --output .\benchmarks\prompt-soak.json

# Full generations across six roughly one-megapixel resolutions
.\env\python.exe .\benchmark.py `
  --source-item-id 1 `
  --warmups 0 `
  --runs 6 `
  --variation resolution `
  --output .\benchmarks\resolution-soak.json
```

The console and JSON report resolution, steps, batch size, denoising `it/s`,
end-to-end time, queue time, per-node timings, and first-three versus last-three
stability. Compare `it/s` only when model, quantization, resolution, steps, and
batch size match; cold-start time is reported separately.

## Tested hardware

- Windows 11 Pro
- AMD Radeon RX 9070 XT, 16 GB
- AMD display driver 32.0.31019.2002

The RX 6600 XT `gfx1032` ROCm 10 package set resolves successfully, but its
physical-GPU generation test is pending confirmation from an RX 6600 XT owner.
Other AMD cards are not covered by these profiles.

## Directory layout

```text
invokeai-rocm-windows\
├── env\                # Python, ROCm, InvokeAI, and native kernels
├── miniconda\          # Project-local Conda
├── .cache\             # Installer, model, and compiled GPU caches
├── invokeai-data\      # Models, outputs, database, and invokeai.yaml
├── install-manifests\  # Preflight and package manifests
├── patches\            # Version-checked Windows/INT4 compatibility patches
├── scripts\            # Shared model-installer helper
├── setup.ps1
├── run.ps1
├── install-anima.ps1
├── install-krea2.ps1
└── benchmark.py
```

## Storage cleanup

Installer caches can be purged without deleting models or outputs:

```powershell
$env:PIP_CACHE_DIR = "$PWD\.cache\pip"
.\env\python.exe -m pip cache purge

$env:CONDA_PKGS_DIRS = "$PWD\.cache\conda\pkgs"
.\miniconda\Scripts\conda.exe clean --all --yes
```

Do not delete `env`, `invokeai-data`, or a separate model store unless you
intend to remove the installation or generated data.

## Notes

- The first image after startup includes model loading and kernel warm-up.
- `torch.version.hip` can show an internal component version; the wheel suffix
  and TheRock release identify the ROCm 10 package.
- `torchaudio` is not installed because InvokeAI does not require it for image
  generation.
- PatchMatch may print a nonfatal startup warning; it is optional for these
  text-to-image tests.
