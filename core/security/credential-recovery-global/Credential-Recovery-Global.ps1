function Get-CredentialRecoveryGlobalConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "GLOBAL_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "GLOBAL_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryGlobalRecords {

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

function Save-CredentialRecoveryGlobalRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryGlobalConfig
    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "GLOBAL_RECORD_LIMIT"
    }

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRecoveryGlobalRecord {

    param(
        [Parameter(Mandatory)]
        [string]$GlobalCheckId
    )

    $records = @(Get-CredentialRecoveryGlobalRecords)

    foreach ($record in $records) {

        if ($record.GlobalCheckId -eq $GlobalCheckId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRecoveryGlobalHash {

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

function New-CredentialRecoveryGlobalCheckId {

    return "GLOBAL-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Invoke-CredentialRecoveryGlobalCheck {

    param(
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$ActivationId,
        [Parameter(Mandatory)][string]$IntegrityId,
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

    $config = Get-CredentialRecoveryGlobalConfig

    if (-not $config.enabled) {
        throw "GLOBAL_GUARD_DISABLED"
    }

    if (-not $config.globalConsistencyEnabled) {
        throw "GLOBAL_CONSISTENCY_DISABLED"
    }

    $values = @(
        $RecoveryId
        $AuthorizationId
        $ContextId
        $ActivationId
        $IntegrityId
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
            throw "GLOBAL_BINDING_REQUIRED"
        }
    }

    if ($OldChainId -eq $NewChainId) {
        throw "OLD_CHAIN_REUSE_FORBIDDEN"
    }

    $now = (Get-Date).ToUniversalTime()

    $canonical = (
        $RecoveryId + "|" +
        $AuthorizationId + "|" +
        $ContextId + "|" +
        $ActivationId + "|" +
        $IntegrityId + "|" +
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

    $checkId = New-CredentialRecoveryGlobalCheckId
    $checkHash = Get-CredentialRecoveryGlobalHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        GlobalCheckId          = $checkId
        GlobalCheckHash        = $checkHash
        RecoveryId             = $RecoveryId
        AuthorizationId        = $AuthorizationId
        ContextId              = $ContextId
        ActivationId           = $ActivationId
        IntegrityId            = $IntegrityId
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
        OldChainStatus         = "REVOKED"
        OldLeaseStatus         = "REVOKED"
        OldMaterializationStatus = "REVOKED"
        OldUsageStatus         = "REVOKED"
        NewChainStatus         = "ACTIVE"
        NewLeaseStatus         = "ACTIVE"
        NewMaterializationStatus = "ACTIVE"
        NewUsageStatus         = "ACTIVE"
        NewExecutionStatus     = "AUTHORIZED"
        RecoveryStatus         = "COMPLETED"
        GlobalStatus           = "CONSISTENT"
        Decision               = "ALLOW"
        CreatedAtUtc           = $now.ToString("o")
        RawSecret              = $null
        RawCredential          = $null
    }

    $records = @(Get-CredentialRecoveryGlobalRecords)
    $records += $record

    Save-CredentialRecoveryGlobalRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        GlobalCheckId = $checkId
        GlobalCheckHash = $checkHash
        Status = "CONSISTENT"
        Decision = "ALLOW"
    }
}

function Test-CredentialRecoveryGlobalConsistency {

    param(
        [Parameter(Mandatory)]
        [string]$GlobalCheckId
    )

    $record = Get-CredentialRecoveryGlobalRecord `
        -GlobalCheckId $GlobalCheckId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.GlobalStatus -ne "CONSISTENT") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "GLOBAL_STATE_INVALID"
        }
    }

    if ($record.OldChainStatus -ne "REVOKED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_CHAIN_NOT_REVOKED"
        }
    }

    if ($record.OldLeaseStatus -ne "REVOKED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_LEASE_NOT_REVOKED"
        }
    }

    if ($record.OldMaterializationStatus -ne "REVOKED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_MATERIALIZATION_NOT_REVOKED"
        }
    }

    if ($record.OldUsageStatus -ne "REVOKED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_USAGE_NOT_REVOKED"
        }
    }

    if ($record.NewChainStatus -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_CHAIN_NOT_ACTIVE"
        }
    }

    if ($record.NewLeaseStatus -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_LEASE_NOT_ACTIVE"
        }
    }

    if ($record.NewMaterializationStatus -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_MATERIALIZATION_NOT_ACTIVE"
        }
    }

    if ($record.NewUsageStatus -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_USAGE_NOT_ACTIVE"
        }
    }

    if ($record.NewExecutionStatus -ne "AUTHORIZED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_EXECUTION_NOT_AUTHORIZED"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "GLOBAL_CONSISTENT"
        GlobalCheckId = $GlobalCheckId
    }
}

function Reset-CredentialRecoveryGlobal {

    Save-CredentialRecoveryGlobalRecords
}
