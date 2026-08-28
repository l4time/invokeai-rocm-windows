Set-StrictMode -Version Latest

function Get-InvokeAIGpuProfile {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('gfx1201', 'gfx1032')]
        [string] $Id
    )

    switch ($Id) {
        'gfx1201' {
            return [pscustomobject] @{
                Id = 'gfx1201'
                DisplayName = 'AMD Radeon RX 9070 XT'
                ExpectedNamePattern = 'Radeon RX 9070 XT'
                VramGB = 16
                SupportsKrea2ConvRot = $true
            }
        }
        'gfx1032' {
            return [pscustomobject] @{
                Id = 'gfx1032'
                DisplayName = 'AMD Radeon RX 6600 XT'
                ExpectedNamePattern = 'Radeon RX 6600 XT'
                VramGB = 8
                SupportsKrea2ConvRot = $false
            }
        }
    }
}

function Resolve-InvokeAIGpuProfileId {
    param(
        [Parameter(Mandatory)]
        [string[]] $AdapterNames
    )

    $supportedProfiles = @(
        Get-InvokeAIGpuProfile -Id 'gfx1201'
        Get-InvokeAIGpuProfile -Id 'gfx1032'
    )
    $matches = @(
        foreach ($profile in $supportedProfiles) {
            foreach ($adapterName in $AdapterNames) {
                if ($adapterName -match [regex]::Escape($profile.ExpectedNamePattern)) {
                    $profile
                    break
                }
            }
        }
    )
    if ($matches.Count -ne 1) {
        throw (
            "Could not select exactly one supported GPU from: $($AdapterNames -join ', '). " +
            'Use -GpuProfile gfx1201 or -GpuProfile gfx1032 to override automatic detection.'
        )
    }
    return [string] $matches[0].Id
}

function Select-InvokeAIGpuDevice {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Profile,
        [Parameter(Mandatory)]
        [object[]] $Devices
    )

    $matchingDevices = @(
        $Devices |
            Where-Object {
                [string] $_.name -match [regex]::Escape($Profile.ExpectedNamePattern)
            }
    )
    if ($matchingDevices.Count -ne 1) {
        $detectedGpuText = @(
            $Devices |
                ForEach-Object { "[$($_.index)] $($_.name)" }
        ) -join ', '
        throw (
            "Expected exactly one $($Profile.DisplayName), found " +
            "$($matchingDevices.Count). Detected devices: $detectedGpuText"
        )
    }
    return $matchingDevices[0]
}

function Get-InvokeAIGpuProfileManifestPath {
    param([Parameter(Mandatory)][string] $EnvironmentPath)
    return Join-Path $EnvironmentPath '.invokeai-rocm-profile.json'
}

function Read-InvokeAIGpuProfileManifest {
    param(
        [Parameter(Mandatory)]
        [string] $EnvironmentPath,
        [switch] $AllowMissing
    )

    $manifestPath = Get-InvokeAIGpuProfileManifestPath -EnvironmentPath $EnvironmentPath
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        if ($AllowMissing) {
            return $null
        }
        throw "GPU profile manifest is missing. Run .\setup.ps1 again."
    }

    try {
        $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    }
    catch {
        throw "GPU profile manifest is invalid. Run .\setup.ps1 again. $($_.Exception.Message)"
    }

    if ($manifest.schema_version -ne 1) {
        throw "Unsupported GPU profile manifest schema: $($manifest.schema_version)"
    }
    $null = Get-InvokeAIGpuProfile -Id ([string] $manifest.gpu_profile)
    return $manifest
}

function Write-InvokeAIGpuProfileManifest {
    param(
        [Parameter(Mandatory)]
        [string] $EnvironmentPath,
        [Parameter(Mandatory)]
        [pscustomobject] $Profile,
        [Parameter(Mandatory)]
        [ValidateSet('installing', 'complete')]
        [string] $Status,
        [Parameter(Mandatory)]
        [hashtable] $Versions,
        [int] $DeviceIndex = -1
    )

    New-Item -ItemType Directory -Path $EnvironmentPath -Force | Out-Null
    $manifestPath = Get-InvokeAIGpuProfileManifestPath -EnvironmentPath $EnvironmentPath
    $temporaryPath = "$manifestPath.tmp"
    [ordered] @{
        schema_version = 1
        status = $Status
        gpu_profile = $Profile.Id
        expected_gpu = $Profile.DisplayName
        vram_gb = $Profile.VramGB
        device_index = $DeviceIndex
        versions = $Versions
    } |
        ConvertTo-Json -Depth 4 |
        Set-Content -LiteralPath $temporaryPath -Encoding utf8
    Move-Item -LiteralPath $temporaryPath -Destination $manifestPath -Force
}

function Get-InstalledInvokeAIGpuProfile {
    param(
        [Parameter(Mandatory)]
        [string] $EnvironmentPath
    )

    $manifest = Read-InvokeAIGpuProfileManifest -EnvironmentPath $EnvironmentPath
    if ($manifest.status -ne 'complete') {
        throw "GPU profile setup is incomplete. Rerun .\setup.ps1 -GpuProfile $($manifest.gpu_profile)."
    }
    if ($null -eq $manifest.device_index -or [int] $manifest.device_index -lt 0) {
        throw 'GPU device selection is missing. Run .\setup.ps1 again.'
    }
    $profile = Get-InvokeAIGpuProfile -Id ([string] $manifest.gpu_profile)
    $profile | Add-Member -NotePropertyName DeviceIndex -NotePropertyValue ([int] $manifest.device_index)
    return $profile
}

function Assert-InvokeAIGpuCapability {
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Profile,
        [Parameter(Mandatory)]
        [ValidateSet('krea2-convrot-int4')]
        [string] $Capability
    )

    if ($Capability -eq 'krea2-convrot-int4' -and -not $Profile.SupportsKrea2ConvRot) {
        throw (
            "Krea 2 ConvRot INT4 is not supported by the $($Profile.DisplayName) " +
            "($($Profile.Id), $($Profile.VramGB) GB). This repository's native " +
            'ConvRot kernels are tested only on the RX 9070 XT (gfx1201, 16 GB).'
        )
    }
}
