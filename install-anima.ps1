# Install the tested Anima Turbo v1.1 model set and InvokeAI defaults.

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
        Name = 'Anima Turbo v1.1'
        Source = 'https://civitai.com/api/download/models/3263843?fileId=3147349'
        Hash = '6caae380057827bf247c3b0c4f5b65a29783d021ce9b60ece455e6e2197e4533'
        Install = @{
            name = 'Anima Turbo v1.1'
            base = 'anima'
            type = 'main'
            format = 'checkpoint'
        }
        Config = @{
            name = 'Anima Turbo v1.1'
            base = 'anima'
            type = 'main'
            format = 'checkpoint'
            default_settings = @{
                scheduler = 'er_sde'
                steps = 8
                cfg_scale = 1.0
                width = 1024
                height = 1024
            }
        }
        Verify = @{
            hash = '6caae380057827bf247c3b0c4f5b65a29783d021ce9b60ece455e6e2197e4533'
            base = 'anima'
            type = 'main'
            format = 'checkpoint'
        }
    },
    @{
        Name = 'Anima Qwen3 0.6B Text Encoder'
        Source = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/text_encoders/qwen_3_06b_base.safetensors'
        Hash = 'b9079c6ea657a7cb4ae9add2d24e0f8cfdaff6d2da96d7657a53676e013dede9'
        Install = @{
            name = 'Anima Qwen3 0.6B Text Encoder'
            base = 'any'
            type = 'qwen3_encoder'
            format = 'checkpoint'
            variant = 'qwen3_06b'
        }
        Config = @{
            name = 'Anima Qwen3 0.6B Text Encoder'
            base = 'any'
            type = 'qwen3_encoder'
            format = 'checkpoint'
            variant = 'qwen3_06b'
        }
        Verify = @{
            hash = 'b9079c6ea657a7cb4ae9add2d24e0f8cfdaff6d2da96d7657a53676e013dede9'
            base = 'any'
            type = 'qwen3_encoder'
            format = 'checkpoint'
            variant = 'qwen3_06b'
        }
    },
    @{
        Name = 'Anima QwenImage VAE'
        Source = 'https://huggingface.co/circlestone-labs/Anima/resolve/main/split_files/vae/qwen_image_vae.safetensors'
        Hash = '1018b941788940c4dfc449d5d749950cae58c9a7f6a794b00a2f8321abc885d1'
        Install = @{
            name = 'Anima QwenImage VAE'
            base = 'anima'
            type = 'vae'
            format = 'checkpoint'
        }
        Config = @{
            name = 'Anima QwenImage VAE'
            base = 'anima'
            type = 'vae'
            format = 'checkpoint'
        }
        Verify = @{
            hash = '1018b941788940c4dfc449d5d749950cae58c9a7f6a794b00a2f8321abc885d1'
            base = 'anima'
            type = 'vae'
            format = 'checkpoint'
        }
    }
)

Write-Host 'Anima Turbo v1.1 installer (about 5.3 GB)' -ForegroundColor Cyan
Start-InvokeAIIfNeeded -ApiUrl $ApiUrl -ProjectRoot $ProjectRoot
foreach ($model in $models) {
    $null = Install-InvokeAIModel -ApiUrl $ApiUrl -Spec $model
}

Write-Host "`nAnima Turbo v1.1 is ready: ER-SDE, CFG 1, 8 steps, 1024x1024." -ForegroundColor Green
