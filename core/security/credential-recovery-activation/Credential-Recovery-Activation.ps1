function Get-CredentialRecoveryActivationConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "ACTIVATION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "ACTIVATION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryActivationRecords {

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

function Save-CredentialRecoveryActivationRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryActivationConfig
    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "ACTIVATION_RECORD_LIMIT"
    }

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30
    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRecoveryActivationRecord {

    param(
        [Parameter(Mandatory)]
        [string]$ActivationId
    )

    $records = @(Get-CredentialRecoveryActivationRecords)

    foreach ($record in $records) {

        if ($record.ActivationId -eq $ActivationId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialActivationHash {

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

function New-CredentialActivationId {

    return "ACT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Activate-FreshCredentialRecoveryChain {

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

    $config = Get-CredentialRecoveryActivationConfig

    if (-not $config.enabled) {
        throw "ACTIVATION_DISABLED"
    }

    if (-not $config.activationGuardEnabled) {
        throw "ACTIVATION_GUARD_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        throw "AUTHORIZATION_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ContextId)) {
        throw "CONTEXT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($OldChainId)) {
        throw "OLD_CHAIN_ID_REQUIRED"
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

    if ($OldChainId -eq $NewChainId) {
        throw "OLD_CHAIN_REUSE_FORBIDDEN"
    }

    $records = @(Get-CredentialRecoveryActivationRecords)

    foreach ($existing in $records) {

        if ($existing.NewChainId -eq $NewChainId) {

            throw "CHAIN_ALREADY_ACTIVATED"
        }
    }

    $now = (Get-Date).ToUniversalTime()

    $activationId = New-CredentialActivationId

    $binding = (
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

    $activationHash = Get-CredentialActivationHash -Value $binding

    $record = [pscustomobject][ordered]@{
        ActivationId          = $activationId
        ActivationHash        = $activationHash
        AuthorizationId       = $AuthorizationId
        ContextId             = $ContextId
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
        Status                = "ACTIVE"
        Decision              = "ALLOW"
        CreatedAtUtc          = $now.ToString("o")
        ConsumedAtUtc         = $null
        RawSecret             = $null
        RawCredential         = $null
    }

    $records += $record

    Save-CredentialRecoveryActivationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        ActivationId = $activationId
        ActivationHash = $activationHash
        NewChainId = $NewChainId
        Status = "ACTIVE"
        Decision = "ALLOW"
    }
}

function Test-CredentialRecoveryActivation {

    param(
        [Parameter(Mandatory)][string]$ActivationId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ContextId,
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

    $record = Get-CredentialRecoveryActivationRecord `
        -ActivationId $ActivationId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.Status -ne "ACTIVE") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "INACTIVE"
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

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        ActivationId = $ActivationId
        NewChainId = $record.NewChainId
    }
}

function Consume-CredentialRecoveryActivation {

    param(
        [Parameter(Mandatory)]
        [string]$ActivationId
    )

    $records = @(Get-CredentialRecoveryActivationRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.ActivationId -eq $ActivationId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "ACTIVATION_NOT_FOUND"
    }

    if ($record.Status -ne "ACTIVE") {
        throw "ACTIVATION_NOT_ACTIVE"
    }

    $record.Status = "CONSUMED"
    $record.Decision = "BLOCK"
    $record.ConsumedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialRecoveryActivationRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "CONSUMED"
        ActivationId = $ActivationId
    }
}

function Reset-CredentialRecoveryActivation {

    Save-CredentialRecoveryActivationRecords
}
