# Install the tested RedCraft Krea 2 INT4 model set and InvokeAI defaults.

[CmdletBinding()]
param(
    [string] $ApiUrl = 'http://127.0.0.1:9090'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ProjectRoot = $PSScriptRoot
. (Join-Path $ProjectRoot 'scripts\model-installer.ps1')

$models = @(
    @{
        Name = 'RedCraft 3.0 Krea2 INT4 ConvRot'
        Source = 'https://civitai.com/api/download/models/3139241?fileId=3019523'
        Hash = '76da6e8e45788ab524075a2fad79819f55535eec04302552988f8d1d3ea09a7b'
        Install = @{
            name = 'RedCraft 3.0 Krea2 INT4 ConvRot'
            base = 'krea-2'
            type = 'main'
            format = 'checkpoint'
            variant = 'krea2_turbo'
        }
        Config = @{
            name = 'RedCraft 3.0 Krea2 INT4 ConvRot'
            base = 'krea-2'
            type = 'main'
            format = 'checkpoint'
            variant = 'krea2_turbo'
            default_settings = @{
                scheduler = 'euler'
                steps = 8
                cfg_scale = 1.0
                width = 1024
                height = 1024
            }
        }
        Verify = @{
            hash = '76da6e8e45788ab524075a2fad79819f55535eec04302552988f8d1d3ea09a7b'
            base = 'krea-2'
            type = 'main'
            format = 'checkpoint'
            variant = 'krea2_turbo'
        }
    },
    @{
        Name = 'Krea 2 Qwen3-VL 4B FP8 Encoder'
        Source = 'https://huggingface.co/Comfy-Org/Krea-2/resolve/main/text_encoders/qwen3vl_4b_fp8_scaled.safetensors'
        Hash = 'bf4e4ab393c4b8cc4585427d4b5a32a1fbcaf5fc9c2a74b57e559d8cdcebe432'
        Install = @{
            name = 'Krea 2 Qwen3-VL 4B FP8 Encoder'
            base = 'any'
            type = 'qwen3_vl_encoder'
            format = 'checkpoint'
        }
        Config = @{
            name = 'Krea 2 Qwen3-VL 4B FP8 Encoder'
            base = 'any'
            type = 'qwen3_vl_encoder'
            format = 'checkpoint'
        }
        Verify = @{
            hash = 'bf4e4ab393c4b8cc4585427d4b5a32a1fbcaf5fc9c2a74b57e559d8cdcebe432'
            base = 'any'
            type = 'qwen3_vl_encoder'
            format = 'checkpoint'
        }
    },
    @{
        Name = 'Qwen Image VAE'
        Source = 'https://huggingface.co/Qwen/Qwen-Image-Edit-2511/resolve/main/vae/diffusion_pytorch_model.safetensors'
        Hash = '3b361133a172c51f53fcb3ce6304081cee24ed29446dc2b12e475913462b572c'
        Install = @{
            name = 'Qwen Image VAE'
            base = 'qwen-image'
            type = 'vae'
            format = 'checkpoint'
        }
        Config = @{
            name = 'Qwen Image VAE'
            base = 'qwen-image'
            type = 'vae'
            format = 'checkpoint'
        }
        Verify = @{
            hash = '3b361133a172c51f53fcb3ce6304081cee24ed29446dc2b12e475913462b572c'
            base = 'qwen-image'
            type = 'vae'
            format = 'checkpoint'
        }
    }
)

Write-Host 'RedCraft Krea 2 INT4 installer (about 11.6 GB)' -ForegroundColor Cyan
Start-InvokeAIIfNeeded -ApiUrl $ApiUrl -ProjectRoot $ProjectRoot
foreach ($model in $models) {
    $null = Install-InvokeAIModel -ApiUrl $ApiUrl -Spec $model
}

Write-Host "`nRedCraft Krea 2 is ready: Euler/Simple, CFG 1, 8 steps, 1024x1024." -ForegroundColor Green
