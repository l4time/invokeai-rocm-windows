# Shared InvokeAI model installer helpers. Run install-anima.ps1 or
# install-krea2.ps1 instead of invoking this file directly.

$script:ExpectedInvokeAIVersion = '6.14.0'

function Get-NormalizedModelHash {
    param([Parameter(Mandatory)][string] $Hash)

    $Hash.Trim().ToLowerInvariant() -replace '^blake3:', ''
}

function Invoke-InvokeAIRequest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Get', 'Post', 'Patch')]
        [string] $Method,
        [Parameter(Mandatory)]
        [string] $Uri,
        [Parameter()]
        [hashtable] $Body
    )

    $requestArguments = @{
        Method = $Method
        Uri = $Uri
        UseBasicParsing = $true
    }
    if ($null -ne $Body) {
        $requestArguments.ContentType = 'application/json'
        $requestArguments.Body = $Body | ConvertTo-Json -Depth 10
    }
    Invoke-RestMethod @requestArguments
}

function Get-InvokeAIVersion {
    param([Parameter(Mandatory)][string] $ApiUrl)

    $versionResponse = Invoke-InvokeAIRequest `
        -Method Get `
        -Uri "$($ApiUrl.TrimEnd('/'))/api/v1/app/version"
    if ($versionResponse -is [string]) {
        return $versionResponse
    }
    if ($null -ne $versionResponse.version) {
        return [string] $versionResponse.version
    }
    throw "InvokeAI returned an unexpected version response: $versionResponse"
}

function Start-InvokeAIIfNeeded {
    param(
        [Parameter(Mandatory)]
        [string] $ApiUrl,
        [Parameter(Mandatory)]
        [string] $ProjectRoot
    )

    try {
        $runningVersion = Get-InvokeAIVersion -ApiUrl $ApiUrl
    }
    catch {
        $runningVersion = $null
    }

    if ($null -eq $runningVersion) {
        $runScript = Join-Path $ProjectRoot 'run.ps1'
        if (-not (Test-Path -LiteralPath $runScript)) {
            throw "Cannot find InvokeAI launcher: $runScript"
        }

        Write-Host 'Starting InvokeAI in a separate PowerShell window...' -ForegroundColor Cyan
        $quotedRunScript = '"' + $runScript + '"'
        Start-Process `
            -FilePath 'powershell.exe' `
            -ArgumentList @(
                '-NoProfile',
                '-ExecutionPolicy', 'Bypass',
                '-File', $quotedRunScript
            ) | Out-Null

        $deadline = [DateTime]::UtcNow.AddMinutes(3)
        do {
            Start-Sleep -Seconds 2
            try {
                $runningVersion = Get-InvokeAIVersion -ApiUrl $ApiUrl
            }
            catch {
                $runningVersion = $null
            }
        } while ($null -eq $runningVersion -and [DateTime]::UtcNow -lt $deadline)
    }

    if ($null -eq $runningVersion) {
        throw "InvokeAI did not become ready at $ApiUrl within three minutes."
    }
    if ($runningVersion -ne $script:ExpectedInvokeAIVersion) {
        throw (
            "Expected InvokeAI $($script:ExpectedInvokeAIVersion) at $ApiUrl, " +
            "but found $runningVersion."
        )
    }
    Write-Host "InvokeAI $runningVersion is ready at $ApiUrl" -ForegroundColor Green
}

function Get-InstalledInvokeAIModels {
    param([Parameter(Mandatory)][string] $ApiUrl)

    $response = Invoke-InvokeAIRequest `
        -Method Get `
        -Uri "$($ApiUrl.TrimEnd('/'))/api/v2/models/"
    if ($null -eq $response.models) {
        throw 'InvokeAI returned an unexpected model-list response.'
    }
    @($response.models)
}

function Wait-InvokeAIModelInstall {
    param(
        [Parameter(Mandatory)]
        [string] $ApiUrl,
        [Parameter(Mandatory)]
        [int] $JobId,
        [Parameter(Mandatory)]
        [string] $ModelName
    )

    while ($true) {
        $job = Invoke-InvokeAIRequest `
            -Method Get `
            -Uri "$($ApiUrl.TrimEnd('/'))/api/v2/models/install/$JobId"
        $installState = [string] $job.status

        $bytesProperty = $job.PSObject.Properties['bytes']
        $totalBytesProperty = $job.PSObject.Properties['total_bytes']
        if (
            $null -ne $bytesProperty -and
            $null -ne $totalBytesProperty -and
            [double] $totalBytesProperty.Value -gt 0
        ) {
            $percent = [Math]::Floor(
                100 * [double] $bytesProperty.Value /
                [double] $totalBytesProperty.Value
            )
            Write-Progress `
                -Activity "Installing $ModelName" `
                -Status "$installState ($percent%)" `
                -PercentComplete $percent
        }
        else {
            Write-Progress `
                -Activity "Installing $ModelName" `
                -Status $installState
        }

        if ($installState -eq 'completed') {
            Write-Progress -Activity "Installing $ModelName" -Completed
            return $job
        }
        if ($installState -in @('error', 'cancelled')) {
            Write-Progress -Activity "Installing $ModelName" -Completed
            $errorProperty = $job.PSObject.Properties['error_reason']
            $errorReason = if ($null -ne $errorProperty) {
                [string] $errorProperty.Value
            }
            else {
                'No reason returned'
            }
            throw (
                "Installing '$ModelName' ended as $installState`: " +
                $errorReason
            )
        }
        Start-Sleep -Seconds 2
    }
}

function Install-InvokeAIModel {
    param(
        [Parameter(Mandatory)]
        [string] $ApiUrl,
        [Parameter(Mandatory)]
        [hashtable] $Spec
    )

    $expectedHash = Get-NormalizedModelHash -Hash ([string] $Spec.Hash)
    $installedModel = Get-InstalledInvokeAIModels -ApiUrl $ApiUrl |
        Where-Object {
            $null -ne $_.hash -and
            (Get-NormalizedModelHash -Hash ([string] $_.hash)) -eq $expectedHash
        } |
        Select-Object -First 1

    if ($null -eq $installedModel) {
        Write-Host "`nDownloading $($Spec.Name)..." -ForegroundColor Cyan
        $encodedSource = [Uri]::EscapeDataString([string] $Spec.Source)
        $installJob = Invoke-InvokeAIRequest `
            -Method Post `
            -Uri "$($ApiUrl.TrimEnd('/'))/api/v2/models/install?source=$encodedSource" `
            -Body $Spec.Install
        $installJob = Wait-InvokeAIModelInstall `
            -ApiUrl $ApiUrl `
            -JobId ([int] $installJob.id) `
            -ModelName $Spec.Name
        $modelKey = [string] $installJob.config_out.key
        if ([string]::IsNullOrWhiteSpace($modelKey)) {
            throw "InvokeAI completed '$($Spec.Name)' without returning a model key."
        }
    }
    else {
        $modelKey = [string] $installedModel.key
        Write-Host "`nAlready downloaded: $($Spec.Name)" -ForegroundColor DarkGray
    }

    $null = Invoke-InvokeAIRequest `
        -Method Patch `
        -Uri "$($ApiUrl.TrimEnd('/'))/api/v2/models/i/$modelKey" `
        -Body $Spec.Config

    $verifiedModel = Invoke-InvokeAIRequest `
        -Method Get `
        -Uri "$($ApiUrl.TrimEnd('/'))/api/v2/models/i/$modelKey"
    $verifiedHash = Get-NormalizedModelHash -Hash ([string] $verifiedModel.hash)
    if ($verifiedHash -ne $expectedHash) {
        throw (
            "Verification failed for '$($Spec.Name)': expected hash " +
            "'$expectedHash', found '$($verifiedModel.hash)'."
        )
    }
    foreach ($field in @('base', 'type', 'format')) {
        if ([string] $verifiedModel.$field -ine [string] $Spec.Verify.$field) {
            throw (
                "Verification failed for '$($Spec.Name)': expected $field " +
                "'$($Spec.Verify.$field)', found '$($verifiedModel.$field)'."
            )
        }
    }
    if (
        $Spec.Verify.ContainsKey('variant') -and
        [string] $verifiedModel.variant -ine [string] $Spec.Verify.variant
    ) {
        throw (
            "Verification failed for '$($Spec.Name)': expected variant " +
            "'$($Spec.Verify.variant)', found '$($verifiedModel.variant)'."
        )
    }

    Write-Host "Ready: $($verifiedModel.name) [$modelKey]" -ForegroundColor Green
    $verifiedModel
}
