Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$StatePath = Join-Path $RuntimeRoot "state\admissions.json"

function Get-AdmissionConfig {
    $configPath = Join-Path $RuntimeRoot "EXECUTION-ADMISSION-CONFIG.json"

    if (-not (Test-Path -LiteralPath $configPath)) {
        throw "Configuration Admission introuvable."
    }

    return (Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json)
}

function Assert-AdmissionIdentity {
    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId obligatoire."
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId obligatoire."
    }

    if ($ExecutionId -match "[\r\n]" -or $TenantId -match "[\r\n]") {
        throw "Contexte invalide."
    }
}

function Get-AdmissionState {
    if (-not (Test-Path -LiteralPath $StatePath)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $StatePath -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $data = $raw | ConvertFrom-Json

    if ($null -eq $data) {
        return @()
    }

    if ($data -is [System.Array]) {
        return @($data)
    }

    return @($data)
}

function Save-AdmissionState {
    param(
        [object[]]$State
    )

    $State | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $StatePath -Encoding UTF8
}

function Get-AdmissionRecord {
    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    Assert-AdmissionIdentity -ExecutionId $ExecutionId -TenantId $TenantId

    $state = Get-AdmissionState

    return $state |
        Where-Object {
            $_.ExecutionId -eq $ExecutionId -and
            $_.TenantId -eq $TenantId
        } |
        Select-Object -First 1
}

function New-AdmissionRecord {
    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $config = Get-AdmissionConfig

    if (-not $config.enabled -or -not $config.admissionGateEnabled) {
        throw "Admission Gate désactivé."
    }

    Assert-AdmissionIdentity -ExecutionId $ExecutionId -TenantId $TenantId

    if ($null -ne (Get-AdmissionRecord `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId)) {
        throw "Admission déjà enregistrée."
    }

    $state = @(Get-AdmissionState)

    if ($state.Count -ge [int]$config.maxAdmissions) {
        throw "Limite maximale d'admissions atteinte."
    }

    $record = [pscustomobject]@{
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        AdmissionStatus = "PENDING"
        Ready = $false
        DependenciesReady = $false
        DeadlineReady = $false
        SecurityReady = $false
        LiveAllowed = $false
        Reason = "PENDING_CHECKS"
        CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
        UpdatedAtUtc = [DateTime]::UtcNow.ToString("o")
    }

    $state += $record
    Save-AdmissionState -State $state

    return $record
}

function Test-AdmissionSecurity {
    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    Assert-AdmissionIdentity -ExecutionId $ExecutionId -TenantId $TenantId

    $config = Get-AdmissionConfig

    if (-not $config.strictMode) {
        return $false
    }

    if (-not $config.requireTenantIsolation) {
        return $false
    }

    if ($config.captureSecrets) {
        return $false
    }

    if ($config.capturePayloads) {
        return $false
    }

    if ($config.liveExecutionEnabled) {
        return $false
    }

    return $true
}

function Test-AdmissionDependencies {
    param(
        [bool]$DependenciesCompleted
    )

    return [bool]$DependenciesCompleted
}

function Test-AdmissionDeadline {
    param(
        [bool]$DeadlineValid
    )

    return [bool]$DeadlineValid
}

function Test-ExecutionAdmission {
    param(
        [string]$ExecutionId,
        [string]$TenantId,
        [bool]$DependenciesCompleted,
        [bool]$DeadlineValid
    )

    Assert-AdmissionIdentity -ExecutionId $ExecutionId -TenantId $TenantId

    $config = Get-AdmissionConfig

    if (-not $config.enabled -or -not $config.admissionGateEnabled) {
        throw "Admission Gate indisponible."
    }

    $record = Get-AdmissionRecord `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $record) {
        throw "Admission inconnue."
    }

    $securityReady = Test-AdmissionSecurity `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    $dependenciesReady = $true

    if ($config.dependencyChecksEnabled) {
        $dependenciesReady = Test-AdmissionDependencies `
            -DependenciesCompleted:$DependenciesCompleted
    }

    $deadlineReady = $true

    if ($config.deadlineChecksEnabled) {
        $deadlineReady = Test-AdmissionDeadline `
            -DeadlineValid:$DeadlineValid
    }

    $ready =
        $securityReady -and
        $dependenciesReady -and
        $deadlineReady

    if ($ready) {
        $status = "ADMITTED"
        $reason = "READY"
    }
    else {
        $status = "BLOCKED"

        $reasons = @()

        if (-not $securityReady) {
            $reasons += "SECURITY"
        }

        if (-not $dependenciesReady) {
            $reasons += "DEPENDENCIES"
        }

        if (-not $deadlineReady) {
            $reasons += "DEADLINE"
        }

        $reason = $reasons -join ","
    }

    $state = @(Get-AdmissionState)

    $updated = foreach ($item in $state) {
        if (
            $item.ExecutionId -eq $ExecutionId -and
            $item.TenantId -eq $TenantId
        ) {
            [pscustomobject]@{
                ExecutionId = $item.ExecutionId
                TenantId = $item.TenantId
                AdmissionStatus = $status
                Ready = $ready
                DependenciesReady = $dependenciesReady
                DeadlineReady = $deadlineReady
                SecurityReady = $securityReady
                LiveAllowed = $false
                Reason = $reason
                CreatedAtUtc = $item.CreatedAtUtc
                UpdatedAtUtc = [DateTime]::UtcNow.ToString("o")
            }
        }
        else {
            $item
        }
    }

    Save-AdmissionState -State $updated

    return ($updated |
        Where-Object {
            $_.ExecutionId -eq $ExecutionId -and
            $_.TenantId -eq $TenantId
        } |
        Select-Object -First 1)
}

function Get-ExecutionAdmission {
    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    return Get-AdmissionRecord `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId
}

function Test-AdmissionReady {
    param(
        [string]$ExecutionId,
        [string]$TenantId
    )

    $record = Get-AdmissionRecord `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId

    if ($null -eq $record) {
        return $false
    }

    return [bool]$record.Ready
}

function Reset-AdmissionState {
    if (Test-Path -LiteralPath $StatePath) {
        Remove-Item -LiteralPath $StatePath -Force
    }
}

Export-ModuleMember -Function `
    Get-AdmissionConfig, `
    Get-AdmissionState, `
    Save-AdmissionState, `
    Get-AdmissionRecord, `
    New-AdmissionRecord, `
    Test-AdmissionSecurity, `
    Test-AdmissionDependencies, `
    Test-AdmissionDeadline, `
    Test-ExecutionAdmission, `
    Get-ExecutionAdmission, `
    Test-AdmissionReady, `
    Reset-AdmissionState
