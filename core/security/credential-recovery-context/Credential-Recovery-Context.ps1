function Get-CredentialRecoveryContextConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CONTEXT_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CONTEXT_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryContextRecords {

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

function Save-CredentialRecoveryContextRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryContextConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CONTEXT_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRecoveryContextRecord {

    param(
        [Parameter(Mandatory)]
        [string]$ContextId
    )

    $records = @(Get-CredentialRecoveryContextRecords)

    foreach ($record in $records) {

        if ($record.ContextId -eq $ContextId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRecoveryContextHash {

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

function New-CredentialRecoveryContextId {

    return "CTX-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-RecoveryContextRecord {

    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId
    )

    $config = Get-CredentialRecoveryContextConfig

    if (-not $config.enabled) {
        throw "CONTEXT_GUARD_DISABLED"
    }

    if (-not $config.contextRevalidationEnabled) {
        throw "CONTEXT_REVALIDATION_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        throw "AUTHORIZATION_ID_REQUIRED"
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

    if ([string]::IsNullOrWhiteSpace($NewChainId)) {
        throw "NEW_CHAIN_ID_REQUIRED"
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

    $now = (Get-Date).ToUniversalTime()

    $contextId = New-CredentialRecoveryContextId

    $canonical = (
        $AuthorizationId + "|" +
        $UserId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $NewChainId + "|" +
        $NewLeaseId + "|" +
        $NewMaterializationId + "|" +
        $NewUsageId + "|" +
        $NewExecutionId
    )

    $contextHash = Get-CredentialRecoveryContextHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        ContextId              = $contextId
        ContextHash            = $contextHash
        AuthorizationId        = $AuthorizationId
        UserId                 = $UserId
        TenantId               = $TenantId
        ClientId               = $ClientId
        ProjectId              = $ProjectId
        WorkerId               = $WorkerId
        Action                 = $Action
        Connector              = $Connector
        NewChainId             = $NewChainId
        NewLeaseId             = $NewLeaseId
        NewMaterializationId   = $NewMaterializationId
        NewUsageId             = $NewUsageId
        NewExecutionId         = $NewExecutionId
        Status                 = "VALID"
        Decision               = "ALLOW"
        CreatedAtUtc           = $now.ToString("o")
        RevokedAtUtc           = $null
        RawSecret              = $null
        RawCredential          = $null
    }

    $records = @(Get-CredentialRecoveryContextRecords)

    $records += $record

    Save-CredentialRecoveryContextRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        ContextId = $contextId
        ContextHash = $contextHash
        Status = "VALID"
        Decision = "ALLOW"
    }
}

function Test-CredentialRecoveryContext {

    param(
        [Parameter(Mandatory)][string]$ContextId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector,
        [Parameter(Mandatory)][string]$NewChainId,
        [Parameter(Mandatory)][string]$NewLeaseId,
        [Parameter(Mandatory)][string]$NewMaterializationId,
        [Parameter(Mandatory)][string]$NewUsageId,
        [Parameter(Mandatory)][string]$NewExecutionId
    )

    $config = Get-CredentialRecoveryContextConfig

    if (-not $config.enabled) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "DISABLED"
        }
    }

    $record = Get-CredentialRecoveryContextRecord `
        -ContextId $ContextId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Status -ne "VALID") {
        return [pscustomobject]@{
            Allowed = $false
            Code = "INVALID_CONTEXT"
        }
    }

    if ($record.AuthorizationId -ne $AuthorizationId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "AUTHORIZATION_SUBSTITUTION"
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

    if ($record.NewChainId -ne $NewChainId) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "CHAIN_SUBSTITUTION"
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

    $canonical = (
        $AuthorizationId + "|" +
        $UserId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $NewChainId + "|" +
        $NewLeaseId + "|" +
        $NewMaterializationId + "|" +
        $NewUsageId + "|" +
        $NewExecutionId
    )

    $candidateHash = Get-CredentialRecoveryContextHash `
        -Value $canonical

    if ($candidateHash -ne $record.ContextHash) {
        return [pscustomobject]@{
            Allowed = $false
            Code = "CONTEXT_INTEGRITY_FAILURE"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "CONTEXT_VALID"
        ContextId = $ContextId
    }
}

function Revoke-CredentialRecoveryContext {

    param(
        [Parameter(Mandatory)]
        [string]$ContextId
    )

    $records = @(Get-CredentialRecoveryContextRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.ContextId -eq $ContextId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "CONTEXT_NOT_FOUND"
    }

    $record.Status = "REVOKED"
    $record.Decision = "BLOCK"
    $record.RevokedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialRecoveryContextRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "REVOKED"
        ContextId = $ContextId
    }
}

function Reset-CredentialRecoveryContext {

    Save-CredentialRecoveryContextRecords
}
