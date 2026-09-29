function Get-CredentialRecoveryAuthorizationConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "RECOVERY_AUTH_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "RECOVERY_AUTH_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialRecoveryAuthorizationRecords {

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

function Save-CredentialRecoveryAuthorizationRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialRecoveryAuthorizationConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "RECOVERY_AUTH_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 30

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialRecoveryAuthorizationRecord {

    param(
        [Parameter(Mandatory)]
        [string]$AuthorizationId
    )

    $records = @(Get-CredentialRecoveryAuthorizationRecords)

    foreach ($record in $records) {

        if ($record.AuthorizationId -eq $AuthorizationId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialRecoveryAuthorizationHash {

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

function New-RecoveryAuthorizationId {

    return "RAUTH-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-FreshChainId {

    return "CHAIN-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-FreshLeaseId {

    return "LEASE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-FreshMaterializationId {

    return "MAT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-FreshUsageId {

    return "USE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function New-FreshExecutionId {

    return "EXEC-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Get-ParentRecoveryRecord {

    param(
        [Parameter(Mandatory)]
        [string]$ParentRecoveryId
    )

    # --------------------------------------------------------
    # Source officielle : 8A-23 state\records.json
    # --------------------------------------------------------

    $recoveryRoot = Join-Path `
        (Split-Path $PSScriptRoot -Parent) `
        "credential-revocation-recovery"

    $statePath = Join-Path `
        $recoveryRoot `
        "state\records.json"

    if (-not (Test-Path -LiteralPath $statePath)) {
        throw "RECOVERY_8A23_STATE_MISSING"
    }

    $raw = Get-Content -LiteralPath $statePath -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "RECOVERY_8A23_STATE_EMPTY"
    }

    $data = $raw | ConvertFrom-Json

    if ($null -eq $data) {
        throw "RECOVERY_8A23_STATE_INVALID"
    }

    if ($data -is [System.Array]) {
        $records = @($data)
    }
    else {
        $records = @($data)
    }

    foreach ($record in $records) {

        if ($record.RecoveryId -eq $ParentRecoveryId) {
            return $record
        }
    }

    return $null
}

function Authorize-CredentialRecovery {

    param(
        [Parameter(Mandatory)][string]$ParentRecoveryId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $config = Get-CredentialRecoveryAuthorizationConfig

    if (-not $config.enabled) {
        throw "RECOVERY_AUTH_DISABLED"
    }

    if (-not $config.recoveryAuthorizationEnabled) {
        throw "RECOVERY_AUTH_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($ParentRecoveryId)) {
        throw "PARENT_RECOVERY_ID_REQUIRED"
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

    $parent = Get-ParentRecoveryRecord `
        -ParentRecoveryId $ParentRecoveryId

    if ($null -eq $parent) {
        throw "PARENT_RECOVERY_NOT_FOUND"
    }

    if ($parent.RecoveryStatus -ne "CLOSED") {
        throw "PARENT_RECOVERY_NOT_CLOSED"
    }

    if ($parent.ChainStatus -ne "REVOKED") {
        throw "PARENT_CHAIN_NOT_REVOKED"
    }

    if (
        $parent.UserId -and
        ($parent.UserId -ne $UserId)
    ) {
        throw "PARENT_USER_MISMATCH"
    }

    if (
        $parent.TenantId -and
        ($parent.TenantId -ne $TenantId)
    ) {
        throw "PARENT_TENANT_MISMATCH"
    }

    if (
        $parent.ClientId -and
        ($parent.ClientId -ne $ClientId)
    ) {
        throw "PARENT_CLIENT_MISMATCH"
    }

    if (
        $parent.ProjectId -and
        ($parent.ProjectId -ne $ProjectId)
    ) {
        throw "PARENT_PROJECT_MISMATCH"
    }

    $now = (Get-Date).ToUniversalTime()

    $authorizationId = New-RecoveryAuthorizationId
    $newChainId = New-FreshChainId
    $newLeaseId = New-FreshLeaseId
    $newMaterializationId = New-FreshMaterializationId
    $newUsageId = New-FreshUsageId
    $newExecutionId = New-FreshExecutionId

    $binding = (
        $authorizationId + "|" +
        $ParentRecoveryId + "|" +
        $UserId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $WorkerId + "|" +
        $Action + "|" +
        $Connector + "|" +
        $newChainId + "|" +
        $newLeaseId + "|" +
        $newMaterializationId + "|" +
        $newUsageId + "|" +
        $newExecutionId
    )

    $authorizationHash = Get-CredentialRecoveryAuthorizationHash `
        -Value $binding

    $record = [pscustomobject][ordered]@{
        AuthorizationId       = $authorizationId
        AuthorizationHash     = $authorizationHash
        ParentRecoveryId      = $ParentRecoveryId
        ParentChainId         = $parent.ChainId
        UserId                = $UserId
        TenantId              = $TenantId
        ClientId              = $ClientId
        ProjectId             = $ProjectId
        WorkerId              = $WorkerId
        Action                = $Action
        Connector             = $Connector
        NewChainId            = $newChainId
        NewLeaseId            = $newLeaseId
        NewMaterializationId  = $newMaterializationId
        NewUsageId            = $newUsageId
        NewExecutionId        = $newExecutionId
        ParentChainStatus     = "REVOKED"
        AuthorizationStatus   = "AUTHORIZED"
        Decision              = "ALLOW"
        CreatedAtUtc          = $now.ToString("o")
        ConsumedAtUtc         = $null
        RevokedAtUtc          = $null
        RawSecret             = $null
        RawCredential         = $null
    }

    $records = @(Get-CredentialRecoveryAuthorizationRecords)

    $records += $record

    Save-CredentialRecoveryAuthorizationRecords `
        -Records $records

    return [pscustomobject][ordered]@{
        Allowed = $true
        AuthorizationId = $authorizationId
        AuthorizationHash = $authorizationHash
        ParentRecoveryId = $ParentRecoveryId
        NewChainId = $newChainId
        NewLeaseId = $newLeaseId
        NewMaterializationId = $newMaterializationId
        NewUsageId = $newUsageId
        NewExecutionId = $newExecutionId
        Status = "AUTHORIZED"
    }
}

function Test-CredentialRecoveryAuthorization {

    param(
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ParentRecoveryId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$WorkerId,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Connector
    )

    $record = Get-CredentialRecoveryAuthorizationRecord `
        -AuthorizationId $AuthorizationId

    if ($null -eq $record) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_FOUND"
        }
    }

    if ($record.AuthorizationStatus -ne "AUTHORIZED") {

        return [pscustomobject]@{
            Allowed = $false
            Code = "NOT_AUTHORIZED"
        }
    }

    if ($record.ParentRecoveryId -ne $ParentRecoveryId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "PARENT_SUBSTITUTION"
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
        AuthorizationId = $AuthorizationId
        NewChainId = $record.NewChainId
    }
}

function Consume-CredentialRecoveryAuthorization {

    param(
        [Parameter(Mandatory)]
        [string]$AuthorizationId
    )

    $records = @(Get-CredentialRecoveryAuthorizationRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.AuthorizationId -eq $AuthorizationId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "AUTHORIZATION_NOT_FOUND"
    }

    if ($record.AuthorizationStatus -ne "AUTHORIZED") {
        throw "AUTHORIZATION_NOT_ACTIVE"
    }

    $record.AuthorizationStatus = "CONSUMED"
    $record.Decision = "BLOCK"
    $record.ConsumedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialRecoveryAuthorizationRecords `
        -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "CONSUMED"
        AuthorizationId = $AuthorizationId
    }
}

function Reset-CredentialRecoveryAuthorization {

    Save-CredentialRecoveryAuthorizationRecords
}
