function Get-CredentialMaterializationConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "CREDENTIAL_MATERIALIZATION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "CREDENTIAL_MATERIALIZATION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-CredentialMaterializationRecords {

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

function Save-CredentialMaterializationRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-CredentialMaterializationConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "CREDENTIAL_MATERIALIZATION_RECORD_LIMIT"
    }

    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -eq 0) {
        Set-Content -LiteralPath $path -Value "[]" -Encoding UTF8
        return
    }

    $json = ConvertTo-Json -InputObject @($Records) -Depth 20

    Set-Content -LiteralPath $path -Value $json -Encoding UTF8
}

function Get-CredentialMaterializationRecord {

    param(
        [Parameter(Mandatory)]
        [string]$MaterializationId
    )

    $records = @(Get-CredentialMaterializationRecords)

    foreach ($record in $records) {

        if ($record.MaterializationId -eq $MaterializationId) {
            return $record
        }
    }

    return $null
}

function Get-CredentialMaterializationHash {

    param(
        [Parameter(Mandatory)]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()

    try {

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        $hash = $sha.ComputeHash($bytes)

        return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-CredentialMaterializationId {
    return "MAT-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Ensure-CredentialLeaseValidator {

    if (Get-Command Test-CredentialLease -ErrorAction SilentlyContinue) {
        return
    }

    $leaseRuntime = Join-Path (
        Split-Path $PSScriptRoot -Parent
    ) "credential-lease\Credential-Lease.ps1"

    if (-not (Test-Path -LiteralPath $leaseRuntime)) {
        throw "CREDENTIAL_LEASE_RUNTIME_MISSING"
    }

    . $leaseRuntime

    if (-not (Get-Command Test-CredentialLease -ErrorAction SilentlyContinue)) {
        throw "CREDENTIAL_LEASE_VALIDATOR_MISSING"
    }
}

function Invoke-CredentialLeaseValidation {

    param(
        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$WorkerId,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Connector,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$TenantId
    )

    Ensure-CredentialLeaseValidator

    $command = Get-Command Test-CredentialLease -ErrorAction Stop

    # --------------------------------------------------------
    # IMPORTANT:
    # Le runtime appelle uniquement les paramètres réellement
    # exposés par 8A-16.
    # --------------------------------------------------------

    $arguments = @{
        LeaseId       = $LeaseId
        CredentialRef = $CredentialRef
        ExecutionId   = $ExecutionId
        WorkerId      = $WorkerId
        Action        = $Action
        Connector     = $Connector
        ProjectId     = $ProjectId
        ClientId      = $ClientId
        TenantId      = $TenantId
    }

    if ($command.Parameters.ContainsKey("UserId")) {

        $arguments["UserId"] = "USER-8A17-001"
    }

    if ($command.Parameters.ContainsKey("SessionId")) {

        $arguments["SessionId"] = "SESSION-8A17-001"
    }

    $result = & $command @arguments

    if ($null -eq $result) {
        throw "CREDENTIAL_LEASE_VALIDATION_EMPTY"
    }

    return $result
}

function New-CredentialMaterialization {

    param(
        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$WorkerId,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Connector,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $config = Get-CredentialMaterializationConfig

    if (-not $config.enabled) {
        throw "CREDENTIAL_MATERIALIZATION_DISABLED"
    }

    if (-not $config.materializationEnabled) {
        throw "CREDENTIAL_MATERIALIZATION_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($LeaseId)) {
        throw "LEASE_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($CredentialRef)) {
        throw "CREDENTIAL_REF_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "EXECUTION_ID_REQUIRED"
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

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "PROJECT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "CLIENT_ID_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TENANT_ID_REQUIRED"
    }

    # ========================================================
    # 8A-16 VALIDATION
    # ========================================================

    $leaseResult = Invoke-CredentialLeaseValidation `
        -LeaseId $LeaseId `
        -CredentialRef $CredentialRef `
        -ExecutionId $ExecutionId `
        -WorkerId $WorkerId `
        -Action $Action `
        -Connector $Connector `
        -ProjectId $ProjectId `
        -ClientId $ClientId `
        -TenantId $TenantId

    if ($leaseResult.Allowed -ne $true) {
        throw "CREDENTIAL_LEASE_NOT_AUTHORIZED"
    }

    # ========================================================
    # MATERIALIZATION
    # ========================================================

    $now = (Get-Date).ToUniversalTime()
    $expires = $now.AddSeconds([int]$config.handleDurationSeconds)

    $materializationId = New-CredentialMaterializationId

    $materializationHash = Get-CredentialMaterializationHash `
        -Value $materializationId

    $credentialRefHash = Get-CredentialMaterializationHash `
        -Value $CredentialRef

    $record = [pscustomobject][ordered]@{
        MaterializationId   = $materializationId
        MaterializationHash = $materializationHash
        LeaseId             = $LeaseId
        CredentialRefHash   = $credentialRefHash
        ExecutionId         = $ExecutionId
        WorkerId            = $WorkerId
        Action              = $Action
        Connector           = $Connector
        ProjectId           = $ProjectId
        ClientId            = $ClientId
        TenantId            = $TenantId
        CreatedAtUtc        = $now.ToString("o")
        ExpiresAtUtc        = $expires.ToString("o")
        ConsumedAtUtc       = $null
        RevokedAtUtc        = $null
        Status              = "ACTIVE"
        Used                = $false
        Decision            = "ALLOW"
        RawSecret           = $null
        RawCredential       = $null
    }

    $records = @(Get-CredentialMaterializationRecords)

    $records += $record

    Save-CredentialMaterializationRecords -Records $records

    return [pscustomobject][ordered]@{
        Allowed             = $true
        MaterializationId   = $materializationId
        MaterializationHash = $materializationHash
        LeaseId             = $LeaseId
        ExecutionId         = $ExecutionId
        WorkerId            = $WorkerId
        Action              = $Action
        Connector           = $Connector
        ProjectId           = $ProjectId
        ClientId            = $ClientId
        TenantId            = $TenantId
        ExpiresAtUtc        = $expires.ToString("o")
    }
}

function Test-CredentialMaterialization {

    param(
        [Parameter(Mandatory)]
        [string]$MaterializationId,

        [Parameter(Mandatory)]
        [string]$LeaseId,

        [Parameter(Mandatory)]
        [string]$CredentialRef,

        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$WorkerId,

        [Parameter(Mandatory)]
        [string]$Action,

        [Parameter(Mandatory)]
        [string]$Connector,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$TenantId
    )

    $config = Get-CredentialMaterializationConfig

    if (-not $config.enabled) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "DISABLED"
        }
    }

    $record = Get-CredentialMaterializationRecord `
        -MaterializationId $MaterializationId

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

    if ($record.Used -eq $true) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "ALREADY_USED"
        }
    }

    $now = (Get-Date).ToUniversalTime()
    $expires = [datetime]::Parse(
        $record.ExpiresAtUtc
    ).ToUniversalTime()

    if ($now -ge $expires) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "EXPIRED"
        }
    }

    if ($record.LeaseId -ne $LeaseId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "LEASE_SUBSTITUTION"
        }
    }

    if ($record.ExecutionId -ne $ExecutionId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "EXECUTION_SUBSTITUTION"
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

    if ($record.ProjectId -ne $ProjectId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "PROJECT_SUBSTITUTION"
        }
    }

    if ($record.ClientId -ne $ClientId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CLIENT_SUBSTITUTION"
        }
    }

    if ($record.TenantId -ne $TenantId) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "TENANT_SUBSTITUTION"
        }
    }

    $candidateHash = Get-CredentialMaterializationHash `
        -Value $CredentialRef

    if ($candidateHash -ne $record.CredentialRefHash) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "CREDENTIAL_REF_SUBSTITUTION"
        }
    }

    if ([string]::IsNullOrWhiteSpace(
        $record.MaterializationHash
    )) {

        return [pscustomobject]@{
            Allowed = $false
            Code = "MATERIALIZATION_HASH_MISSING"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Code = "AUTHORIZED"
        MaterializationId = $record.MaterializationId
        MaterializationHash = $record.MaterializationHash
        ExpiresAtUtc = $record.ExpiresAtUtc
    }
}

function Consume-CredentialMaterialization {

    param(
        [Parameter(Mandatory)]
        [string]$MaterializationId
    )

    $records = @(Get-CredentialMaterializationRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.MaterializationId -eq $MaterializationId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "MATERIALIZATION_NOT_FOUND"
    }

    if ($record.Status -ne "ACTIVE") {
        throw "MATERIALIZATION_NOT_ACTIVE"
    }

    if ($record.Used -eq $true) {
        throw "MATERIALIZATION_ALREADY_USED"
    }

    $record.Used = $true
    $record.Status = "CONSUMED"
    $record.ConsumedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialMaterializationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "CONSUMED"
        MaterializationId = $MaterializationId
    }
}

function Revoke-CredentialMaterialization {

    param(
        [Parameter(Mandatory)]
        [string]$MaterializationId
    )

    $records = @(Get-CredentialMaterializationRecords)

    $record = $null

    foreach ($item in $records) {

        if ($item.MaterializationId -eq $MaterializationId) {
            $record = $item
            break
        }
    }

    if ($null -eq $record) {
        throw "MATERIALIZATION_NOT_FOUND"
    }

    $record.Status = "REVOKED"
    $record.RevokedAtUtc = (
        Get-Date
    ).ToUniversalTime().ToString("o")

    Save-CredentialMaterializationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Status = "REVOKED"
        MaterializationId = $MaterializationId
    }
}

function Reset-CredentialMaterialization {

    Save-CredentialMaterializationRecords
}
