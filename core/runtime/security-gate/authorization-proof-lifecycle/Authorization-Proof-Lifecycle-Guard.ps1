$ErrorActionPreference = "Stop"

$FreshnessModule = Join-Path $PSScriptRoot "..\authorization-proof-freshness\Authorization-Proof-Freshness-Guard.ps1"
$AtomicModule = Join-Path $PSScriptRoot "..\authorization-proof-atomic-consumption\Authorization-Proof-Atomic-Consumption-Guard.ps1"

if (-not (Test-Path -LiteralPath $FreshnessModule -PathType Leaf)) {
    throw "FRESHNESS_MODULE_MISSING"
}

if (-not (Test-Path -LiteralPath $AtomicModule -PathType Leaf)) {
    throw "ATOMIC_MODULE_MISSING"
}

. $FreshnessModule
. $AtomicModule

function Invoke-ProofLifecycleGuard {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][string]$ProofHash
    )

    foreach ($Item in @(
        @{ Name = "TenantId"; Value = $TenantId },
        @{ Name = "ClientId"; Value = $ClientId },
        @{ Name = "ProjectId"; Value = $ProjectId },
        @{ Name = "ExecutionId"; Value = $ExecutionId },
        @{ Name = "UserId"; Value = $UserId },
        @{ Name = "OperationName"; Value = $OperationName },
        @{ Name = "ProofHash"; Value = $ProofHash }
    )) {
        if ([string]::IsNullOrWhiteSpace($Item.Value)) {
            throw "LIFECYCLE_CONTEXT_MISSING:$($Item.Name)"
        }
    }

    # --------------------------------------------------------
    # ETAPE 1 : FRAICHEUR
    # --------------------------------------------------------

    $FreshnessContext = @{
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        ExecutionId = $ExecutionId
        UserId = $UserId
    }

    $FreshnessResult = Test-ProofFreshness `
        -Context $FreshnessContext `
        -Action $OperationName `
        -ProofHash $ProofHash

    if ($FreshnessResult.Decision -ne "ALLOW" -or $FreshnessResult.Valid -ne $true) {
        throw "LIFECYCLE_FRESHNESS_BLOCKED:$($FreshnessResult.Reason)"
    }

    # --------------------------------------------------------
    # ETAPE 2 : ENREGISTREMENT ATOMIQUE EXISTANT
    # --------------------------------------------------------

    $AtomicResult = Test-AtomicProof `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ExecutionId $ExecutionId `
        -UserId $UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash

    if ($AtomicResult.Decision -ne "ALLOW" -or $AtomicResult.Valid -ne $true) {
        throw "LIFECYCLE_ATOMIC_BLOCKED:$($AtomicResult.Reason)"
    }

    # --------------------------------------------------------
    # ETAPE 3 : CONSOMMATION UNIQUE
    # --------------------------------------------------------

    $ConsumeResult = Consume-AtomicProof `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ExecutionId $ExecutionId `
        -UserId $UserId `
        -OperationName $OperationName `
        -ProofHash $ProofHash

    if ($ConsumeResult.Decision -ne "ALLOW" -or $ConsumeResult.Consumed -ne $true) {
        throw "LIFECYCLE_CONSUMPTION_FAILED"
    }

    return [pscustomobject]@{
        Schema = "BK-AI-WORKERS-AUTHORIZATION-PROOF-LIFECYCLE"
        Decision = "ALLOW"
        Authorized = $true
        FreshnessValidated = $true
        AtomicValidated = $true
        AtomicConsumed = $true
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        ExecutionId = $ExecutionId
        UserId = $UserId
        OperationName = $OperationName
        ProofHash = $ProofHash
        ConsumedAtUtc = $ConsumeResult.ConsumedAtUtc
    }
}

function Assert-ProofLifecycleGuard {
    param(
        [Parameter(Mandatory = $true)][string]$TenantId,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$ProjectId,
        [Parameter(Mandatory = $true)][string]$ExecutionId,
        [Parameter(Mandatory = $true)][string]$UserId,
        [Parameter(Mandatory = $true)][string]$OperationName,
        [Parameter(Mandatory = $true)][string]$ProofHash
    )

    $Result = Invoke-ProofLifecycleGuard @PSBoundParameters

    if ($Result.Authorized -ne $true) {
        throw "AUTHORIZATION_PROOF_LIFECYCLE_BLOCKED"
    }

    return $Result
}