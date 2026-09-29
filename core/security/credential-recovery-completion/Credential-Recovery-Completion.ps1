function Get-CredentialRecoveryCompletionConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "COMPLETION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "COMPLETION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryCompletionRecords {

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

function Save-CredentialRecoveryCompletionRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryCompletionConfig
    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "COMPLETION_RECORD_LIMIT"
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

function Get-CredentialRecoveryCompletionRecord {

    param(
        [Parameter(Mandatory)]
        [string]$CompletionId
    )

    $records = @(Get-CredentialRecoveryCompletionRecords)

    foreach ($record in $records) {

        if ($record.CompletionId -eq $CompletionId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRecoveryCompletionHash {

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

function New-CredentialRecoveryCompletionId {

    return "COMP-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Complete-CredentialRecovery {

    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$ActivationId,
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

    $config = Get-CredentialRecoveryCompletionConfig

    if (-not $config.enabled) {
        throw "COMPLETION_DISABLED"
    }

    if (-not $config.completionGuardEnabled) {
        throw "COMPLETION_GUARD_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        throw "AUTHORIZATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ContextId)) {
        throw "CONTEXT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ActivationId)) {
        throw "ACTIVATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($OldChainId)) {
        throw "OLD_CHAIN_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($NewChainId)) {
        throw "NEW_CHAIN_ID_REQUIRED"
    }

    if ($OldChainId -eq $NewChainId) {
        throw "OLD_CHAIN_REUSE_FORBIDDEN"
    }

    if ([string]::IsNullOrWhiteSpace($NewLeaseId)) {
        throw "NEW_LEASE_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($NewMaterializationId)) {
        throw "NEW_MATERIALIZATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($NewUsageId)) {
        throw "NEW_USAGE_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($NewExecutionId)) {
        throw "NEW_EXECUTION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($UserId)) {
        throw "USER_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TENANT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "CLIENT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "PROJECT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($WorkerId)) {
        throw "WORKER_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Action)) {
        throw "ACTION_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Connector)) {
        throw "CONNECTOR_REQUIRED"
    }

    $records = @(Get-CredentialRecoveryCompletionRecords)

    foreach ($existing in $records) {

        if ($existing.NewExecutionId -eq $NewExecutionId) {
            throw "EXECUTION_ALREADY_COMPLETED"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $canonical = (
        $AuthorizationId + "|" +
        $ContextId + "|" +
        $ActivationId + "|" +
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

    $completionId = New-CredentialRecoveryCompletionId
    $completionHash = Get-CredentialRecoveryCompletionHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        CompletionId          = $completionId
        CompletionHash        = $completionHash
        AuthorizationId       = $AuthorizationId
        ContextId             = $ContextId
        ActivationId          = $ActivationId
        OldChainId            = $OldChainId
        NewChainId            = $NewChainId
        NewLeaseId            = $NewLeaseId
        NewMaterializationId  = $NewMaterializationId
        NewUsageId            = $NewUsageId
        NewExecutionId        = $NewExecutionId
        UserId                = $UserId
        TenantId              = $TenantId
        ClientId              = $ClientId
        ProjectId             = $ProjectId
        WorkerId              = $WorkerId
        Action                = $Action
        Connector             = $Connector
        OldChainStatus        = "REVOKED"
        OldLeaseStatus        = "REVOKED"
        OldMaterializationStatus = "REVOKED"
        OldUsageStatus        = "REVOKED"
        NewChainStatus        = "ACTIVE"
        NewLeaseStatus        = "ACTIVE"
        NewMaterializationStatus = "ACTIVE"
        NewUsageStatus        = "ACTIVE"
        NewExecutionStatus    = "AUTHORIZED"
        CompletionStatus      = "COMPLETED"
        Decision              = "ALLOW"
        CreatedAtUtc          = $now.ToString("o")
        CompletedAtUtc        = $now.ToString("o")
        CompletionConsumed    = $true
        ReactivationAllowed   = $false
        RawSecret             = $null
        RawCredential         = $null
    }

    $records += $record

    Save-CredentialRecoveryCompletionRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        CompletionId = $completionId
        CompletionHash = $completionHash
        Status = "COMPLETED"
        Decision = "ALLOW"
    }
}

function Test-CredentialRecoveryCompletion {

    param(
        [Parameter(Mandatory)][string]$CompletionId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$ActivationId,
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

    $record = Get-CredentialRecoveryCompletionRecord `
        -CompletionId $CompletionId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.CompletionStatus -ne "COMPLETED") {
        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_COMPLETED"
        }
    }

    if ($record.CompletionConsumed -ne $true) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_CONSUMED"
        }
    }

    if ($record.ReactivationAllowed -eq $true) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "REACTIVATION_FORBIDDEN"
        }
    }

    if ($record.AuthorizationId -ne $AuthorizationId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "AUTHORIZATION_SUBSTITUTION"
        }
    }

    if ($record.ContextId -ne $ContextId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "CONTEXT_SUBSTITUTION"
        }
    }

    if ($record.ActivationId -ne $ActivationId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "ACTIVATION_SUBSTITUTION"
        }
    }

    if ($record.OldChainId -ne $OldChainId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "OLD_CHAIN_SUBSTITUTION"
        }
    }

    if ($record.NewChainId -ne $NewChainId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "NEW_CHAIN_SUBSTITUTION"
        }
    }

    if ($record.NewLeaseId -ne $NewLeaseId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "LEASE_SUBSTITUTION"
        }
    }

    if ($record.NewMaterializationId -ne $NewMaterializationId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "MATERIALIZATION_SUBSTITUTION"
        }
    }

    if ($record.NewUsageId -ne $NewUsageId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "USAGE_SUBSTITUTION"
        }
    }

    if ($record.NewExecutionId -ne $NewExecutionId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "EXECUTION_SUBSTITUTION"
        }
    }

    if ($record.UserId -ne $UserId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "USER_SUBSTITUTION"
        }
    }

    if ($record.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "TENANT_SUBSTITUTION"
        }
    }

    if ($record.ClientId -ne $ClientId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "CLIENT_SUBSTITUTION"
        }
    }

    if ($record.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "PROJECT_SUBSTITUTION"
        }
    }

    if ($record.WorkerId -ne $WorkerId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "WORKER_SUBSTITUTION"
        }
    }

    if ($record.Action -ne $Action) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "ACTION_SUBSTITUTION"
        }
    }

    if ($record.Connector -ne $Connector) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "CONNECTOR_SUBSTITUTION"
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

    $canonical = (
        $AuthorizationId + "|" +
        $ContextId + "|" +
        $ActivationId + "|" +
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

    $candidateHash = Get-CredentialRecoveryCompletionHash `
        -Value $canonical

    if ($candidateHash -ne $record.CompletionHash) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "COMPLETION_INTEGRITY_FAILURE"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "COMPLETION_VALID"
        CompletionId = $CompletionId
    }
}

function Reset-CredentialRecoveryCompletion {

    Save-CredentialRecoveryCompletionRecords
}
