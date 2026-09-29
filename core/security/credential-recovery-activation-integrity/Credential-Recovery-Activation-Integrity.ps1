function Get-CredentialRecoveryActivationIntegrityConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "ACTIVATION_INTEGRITY_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ACTIVATION_INTEGRITY_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryActivationIntegrityRecords {

    $path = Join-Path $PSScriptRoot "state\records.json"

    if (-not (Test-Path -LiteralPath $path)) {
        return @()
    }

    $raw = Get-Content -LiteralPath $path -Raw

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

function Save-CredentialRecoveryActivationIntegrityRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryActivationIntegrityConfig
    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "ACTIVATION_INTEGRITY_RECORD_LIMIT"
    }

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-CredentialRecoveryActivationIntegrityRecord {

    param(
        [Parameter(Mandatory)]
        [string]$IntegrityId
    )

    $records = @(Get-CredentialRecoveryActivationIntegrityRecords)

    foreach ($record in $records) {

        if ($record.IntegrityId -eq $IntegrityId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialActivationIntegrityHash {

    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $digest = $sha.ComputeHash($bytes)

        return ([System.BitConverter]::ToString($digest)).Replace("-", "").ToLowerInvariant()
    }
    finally {

        $sha.Dispose()
    }
}

function New-CredentialActivationIntegrityId {

    return "INT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-ActivationBindingCanonical {

    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$OldChainId,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    return (
        $AuthorizationId + "|" +
        $ContextId + "|" +
        $OldChainId + "|" +
        $NewChainId + "|" +
        $NewLeaseId + "|" +
        $NewMaterializationId + "|" +
        $NewUsageId + "|" +
        $NewExecutionId + "|" +
        $UserId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector
    )
}

function Register-CredentialRecoveryActivationIntegrity {

    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$OldChainId,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $config = Get-CredentialRecoveryActivationIntegrityConfig

    if (-not $config.enabled) {
        throw "INTEGRITY_DISABLED"
    }

    if (-not $config.integrityGuardEnabled) {
        throw "INTEGRITY_GUARD_DISABLED"
    }

    $values = @(
        $AuthorizationId
        $ContextId
        $OldChainId
        $NewChainId
        $NewLeaseId
        $NewMaterializationId
        $NewUsageId
        $NewExecutionId
        $UserId
        $TenantId
        $ClientId
        $ProjectId
        $WorkerId
        $Action
        $Connector
    )

    foreach ($value in $values) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "ACTIVATION_BINDING_REQUIRED"
        }
    }

    if ($OldChainId -eq $NewChainId) {
        throw "OLD_CHAIN_REUSE_FORBIDDEN"
    }

    $canonical = New-ActivationBindingCanonical `
        -AuthorizationId $AuthorizationId `
        -ContextId $ContextId `
        -OldChainId $OldChainId `
        -NewChainId $NewChainId `
        -NewLeaseId $NewLeaseId `
        -NewMaterializationId $NewMaterializationId `
        -NewUsageId $NewUsageId `
        -NewExecutionId $NewExecutionId `
        -UserId $UserId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -Action $Action `
        -Connector $Connector

    $integrityId = New-CredentialActivationIntegrityId

    $integrityHash = Get-CredentialActivationIntegrityHash `
        -Value $canonical

    $records = @(Get-CredentialRecoveryActivationIntegrityRecords)

    $record = [pscustomobject][ordered]@{
        IntegrityId            = $integrityId
        IntegrityHash          = $integrityHash
        AuthorizationId        = $AuthorizationId
        ContextId              = $ContextId
        OldChainId             = $OldChainId
        NewChainId             = $NewChainId
        NewLeaseId             = $NewLeaseId
        NewMaterializationId   = $NewMaterializationId
        NewUsageId             = $NewUsageId
        NewExecutionId         = $NewExecutionId
        UserId                 = $UserId
        TenantId               = $TenantId
        ClientId               = $ClientId
        ProjectId              = $ProjectId
        WorkerId               = $WorkerId
        Action                 = $Action
        Connector              = $Connector
        Status                 = "VALID"
        Decision               = "ALLOW"
        Immutable              = $true
        CreatedAtUtc           = (
            Get-Date
        ).ToUniversalTime().ToString("o")
        TamperDetectedAtUtc    = $null
        RawSecret              = $null
        RawCredential          = $null
    }

    $records += $record

    Save-CredentialRecoveryActivationIntegrityRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        IntegrityId = $integrityId
        IntegrityHash = $integrityHash
        Status = "VALID"
    }
}

function Test-CredentialRecoveryActivationIntegrity {

    param(
        [Parameter(Mandatory)][string]$IntegrityId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$OldChainId,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $record = Get-CredentialRecoveryActivationIntegrityRecord `
        -IntegrityId $IntegrityId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Immutable -ne $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "IMMUTABILITY_FAILURE"
        }
    }

    if ($record.Status -ne "VALID") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "INVALID_STATUS"
        }
    }

    if ($record.AuthorizationId -ne $AuthorizationId) {
        return [pscustomobject]@{ Allowed=$false; Code="AUTHORIZATION_TAMPER" }
    }

    if ($record.ContextId -ne $ContextId) {
        return [pscustomobject]@{ Allowed=$false; Code="CONTEXT_TAMPER" }
    }

    if ($record.OldChainId -ne $OldChainId) {
        return [pscustomobject]@{ Allowed=$false; Code="OLD_CHAIN_TAMPER" }
    }

    if ($record.NewChainId -ne $NewChainId) {
        return [pscustomobject]@{ Allowed=$false; Code="CHAIN_TAMPER" }
    }

    if ($record.NewLeaseId -ne $NewLeaseId) {
        return [pscustomobject]@{ Allowed=$false; Code="LEASE_TAMPER" }
    }

    if ($record.NewMaterializationId -ne $NewMaterializationId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "MATERIALIZATION_TAMPER"
        }
    }

    if ($record.NewUsageId -ne $NewUsageId) {
        return [pscustomobject]@{ Allowed=$false; Code="USAGE_TAMPER" }
    }

    if ($record.NewExecutionId -ne $NewExecutionId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "EXECUTION_TAMPER"
        }
    }

    if ($record.UserId -ne $UserId) {
        return [pscustomobject]@{ Allowed=$false; Code="USER_TAMPER" }
    }

    if ($record.TenantId -ne $TenantId) {
        return [pscustomobject]@{ Allowed=$false; Code="TENANT_TAMPER" }
    }

    if ($record.ClientId -ne $ClientId) {
        return [pscustomobject]@{ Allowed=$false; Code="CLIENT_TAMPER" }
    }

    if ($record.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{ Allowed=$false; Code="PROJECT_TAMPER" }
    }

    if ($record.WorkerId -ne $WorkerId) {
        return [pscustomobject]@{ Allowed=$false; Code="WORKER_TAMPER" }
    }

    if ($record.Action -ne $Action) {
        return [pscustomobject]@{ Allowed=$false; Code="ACTION_TAMPER" }
    }

    if ($record.Connector -ne $Connector) {
        return [pscustomobject]@{ Allowed=$false; Code="CONNECTOR_TAMPER" }
    }

    $canonical = New-ActivationBindingCanonical `
        -AuthorizationId $AuthorizationId `
        -ContextId $ContextId `
        -OldChainId $OldChainId `
        -NewChainId $NewChainId `
        -NewLeaseId $NewLeaseId `
        -NewMaterializationId $NewMaterializationId `
        -NewUsageId $NewUsageId `
        -NewExecutionId $NewExecutionId `
        -UserId $UserId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -WorkerId $WorkerId `
        -Action $Action `
        -Connector $Connector

    $candidateHash = Get-CredentialActivationIntegrityHash `
        -Value $canonical

    if ($candidateHash -ne $record.IntegrityHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "HASH_MISMATCH"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "INTEGRITY_VALID"
        IntegrityId = $IntegrityId
    }
}

function Mark-CredentialRecoveryActivationTampered {

    param(
        [Parameter(Mandatory)]
        [string]$IntegrityId
    )

    $records = @(Get-CredentialRecoveryActivationIntegrityRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.IntegrityId -eq $IntegrityId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "INTEGRITY_NOT_FOUND"
    }

    $record.Status = "TAMPERED"
    $record.Decision = "BLOCK"
    $record.TamperDetectedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialRecoveryActivationIntegrityRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "TAMPERED"
        IntegrityId = $IntegrityId
    }
}

function Reset-CredentialRecoveryActivationIntegrity {

    Save-CredentialRecoveryActivationIntegrityRecords
}
