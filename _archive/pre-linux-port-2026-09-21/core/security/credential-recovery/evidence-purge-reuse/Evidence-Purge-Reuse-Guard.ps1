#Requires -Version 5.1
$ErrorActionPreference = "Stop"

$ConfigPath = Join-Path $PSScriptRoot "config.json"
$StateDir   = Join-Path $PSScriptRoot "state"
$StatePath  = Join-Path $StateDir "purge-reuse.json"

New-Item -ItemType Directory -Force -Path $StateDir | Out-Null

function Get-EvidencePurgeReuseConfig {
    if (-not (Test-Path -LiteralPath $ConfigPath)) {
        throw "EVIDENCE_PURGE_REUSE_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $ConfigPath -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "EVIDENCE_PURGE_REUSE_CONFIG_EMPTY"
    }

    $config = $raw | ConvertFrom-Json

    foreach ($name in @(
        "enabled",
        "purgeGuardEnabled",
        "reuseGuardEnabled",
        "failClosed",
        "requireEvidenceIdentity",
        "requireRetentionIdentity",
        "requireTenantBinding",
        "requireClientBinding",
        "requireProjectBinding",
        "requireExecutionBinding",
        "requireImmutableEvidence",
        "requireIntegrityValid",
        "denyPurge",
        "denyReuse",
        "denyMutation",
        "secretsProtectionEnabled"
    )) {
        if ($null -eq $config.PSObject.Properties[$name]) {
            throw "EVIDENCE_PURGE_REUSE_CONFIG_INVALID"
        }
    }

    return $config
}

function Get-EvidencePurgeReuseRecords {
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

    return @($data)
}

function Save-EvidencePurgeReuseRecords {
    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-EvidencePurgeReuseConfig

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "EVIDENCE_PURGE_REUSE_RECORD_LIMIT"
    }

    $json = if ($Records.Count -eq 0) { "[]" } else { ConvertTo-Json -InputObject @($Records) -Depth 50 }
    $tmp = "$StatePath.tmp"

    Set-Content -LiteralPath $tmp -Value $json -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $StatePath -Force
}

function Get-EvidencePurgeReuseHash {
    param([Parameter(Mandatory)][string]$Value)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function New-EvidencePurgeReuseId {
    return "PURGE-REUSE-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Get-PurgeReuseRegistrationCanonical {
    param([Parameter(Mandatory)]$Record)

    return (
        [string]$Record.GuardId + "|" +
        [string]$Record.EvidenceId + "|" +
        [string]$Record.RetentionId + "|" +
        [string]$Record.TenantId + "|" +
        [string]$Record.ClientId + "|" +
        [string]$Record.ProjectId + "|" +
        [string]$Record.ExecutionId + "|" +
        [string]$Record.EvidenceHash + "|" +
        [string]$Record.ImmutableEvidence + "|" +
        [string]$Record.IntegrityValid
    )
}

function Get-PurgeReuseStateCanonical {
    param([Parameter(Mandatory)]$Record)

    return (
        [string]$Record.GuardId + "|" +
        [string]$Record.RetentionState + "|" +
        [string]$Record.PurgeDecision + "|" +
        [string]$Record.ReuseDecision + "|" +
        [string]$Record.MutationDecision + "|" +
        [string]$Record.DecisionCode + "|" +
        [string]$Record.Actor + "|" +
        [string]$Record.Reason + "|" +
        [string]$Record.DecisionAtUtc
    )
}

function Update-PurgeReuseStateHash {
    param([Parameter(Mandatory)]$Record)

    $Record.StateHash = Get-EvidencePurgeReuseHash (Get-PurgeReuseStateCanonical -Record $Record)
    return $Record
}

function Find-EvidencePurgeReuseRecord {
    param([Parameter(Mandatory)][string]$GuardId)

    foreach ($record in @(Get-EvidencePurgeReuseRecords)) {
        if ([string]$record.GuardId -eq $GuardId) {
            return $record
        }
    }

    return $null
}

function Register-EvidencePurgeReuseGuard {
    param(
        [Parameter(Mandatory)][string]$EvidenceId,
        [Parameter(Mandatory)][string]$RetentionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$EvidenceHash,
        [Parameter(Mandatory)][bool]$ImmutableEvidence,
        [Parameter(Mandatory)][bool]$IntegrityValid,
        [Parameter(Mandatory)][string]$RetentionState
    )

    $config = Get-EvidencePurgeReuseConfig

    if (-not $config.enabled) { throw "MODULE_DISABLED" }
    if (-not $config.purgeGuardEnabled) { throw "PURGE_GUARD_DISABLED" }
    if (-not $config.reuseGuardEnabled) { throw "REUSE_GUARD_DISABLED" }

    if ($config.requireEvidenceIdentity -and [string]::IsNullOrWhiteSpace($EvidenceId)) { throw "EVIDENCE_ID_REQUIRED" }
    if ($config.requireRetentionIdentity -and [string]::IsNullOrWhiteSpace($RetentionId)) { throw "RETENTION_ID_REQUIRED" }
    if ($config.requireTenantBinding -and [string]::IsNullOrWhiteSpace($TenantId)) { throw "TENANT_ID_REQUIRED" }
    if ($config.requireClientBinding -and [string]::IsNullOrWhiteSpace($ClientId)) { throw "CLIENT_ID_REQUIRED" }
    if ($config.requireProjectBinding -and [string]::IsNullOrWhiteSpace($ProjectId)) { throw "PROJECT_ID_REQUIRED" }
    if ($config.requireExecutionBinding -and [string]::IsNullOrWhiteSpace($ExecutionId)) { throw "EXECUTION_ID_REQUIRED" }
    if ($EvidenceHash -notmatch '^[0-9a-fA-F]{64}$') { throw "EVIDENCE_HASH_INVALID" }
    if ($config.requireImmutableEvidence -and -not $ImmutableEvidence) { throw "IMMUTABLE_EVIDENCE_REQUIRED" }
    if ($config.requireIntegrityValid -and -not $IntegrityValid) { throw "INTEGRITY_REQUIRED" }
    if ($RetentionState -notin @("RETAINED","EXPIRED")) { throw "INVALID_RETENTION_STATE" }

    $record = [pscustomobject][ordered]@{
        GuardId          = New-EvidencePurgeReuseId
        EvidenceId       = $EvidenceId
        RetentionId      = $RetentionId
        TenantId         = $TenantId
        ClientId         = $ClientId
        ProjectId        = $ProjectId
        ExecutionId      = $ExecutionId
        EvidenceHash     = $EvidenceHash.ToLowerInvariant()
        ImmutableEvidence= $ImmutableEvidence
        IntegrityValid   = $IntegrityValid
        RetentionState   = $RetentionState

        PurgeAllowed     = $false
        ReuseAllowed     = $false
        MutationAllowed  = $false

        PurgeDecision    = "BLOCK"
        ReuseDecision    = "BLOCK"
        MutationDecision = "BLOCK"
        Decision         = "BLOCK"
        DecisionCode     = "PURGE_REUSE_DENIED"

        Actor            = ""
        Reason           = ""
        DecisionAtUtc    = ""

        RegistrationAtUtc= ([DateTime]::UtcNow.ToString("o"))
        RegistrationHash = ""
        StateHash        = ""

        RawSecret        = $null
        RawCredential    = $null
    }

    $record.RegistrationHash = Get-EvidencePurgeReuseHash (Get-PurgeReuseRegistrationCanonical -Record $record)
    $record.StateHash = Get-EvidencePurgeReuseHash (Get-PurgeReuseStateCanonical -Record $record)

    $records = @(Get-EvidencePurgeReuseRecords)
    $records += $record
    Save-EvidencePurgeReuseRecords -Records $records

    return $record
}

function Invoke-EvidencePurge {
    param(
        [Parameter(Mandatory)][string]$GuardId,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$Reason
    )

    $config = Get-EvidencePurgeReuseConfig
    $record = Find-EvidencePurgeReuseRecord -GuardId $GuardId

    if ($null -eq $record) { throw "GUARD_NOT_FOUND" }
    if (-not $config.denyPurge) { throw "PURGE_POLICY_INVALID" }

    throw "PURGE_BLOCKED"
}

function Invoke-EvidenceReuse {
    param(
        [Parameter(Mandatory)][string]$GuardId,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$Reason
    )

    $config = Get-EvidencePurgeReuseConfig
    $record = Find-EvidencePurgeReuseRecord -GuardId $GuardId

    if ($null -eq $record) { throw "GUARD_NOT_FOUND" }
    if (-not $config.denyReuse) { throw "REUSE_POLICY_INVALID" }

    throw "REUSE_BLOCKED"
}

function Invoke-EvidenceMutation {
    param(
        [Parameter(Mandatory)][string]$GuardId,
        [Parameter(Mandatory)][string]$Actor,
        [Parameter(Mandatory)][string]$Reason
    )

    $record = Find-EvidencePurgeReuseRecord -GuardId $GuardId
    if ($null -eq $record) { throw "GUARD_NOT_FOUND" }

    throw "MUTATION_BLOCKED"
}

function Test-EvidencePurgeReuse {
    param([Parameter(Mandatory)][string]$GuardId)

    $record = Find-EvidencePurgeReuseRecord -GuardId $GuardId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "GUARD_NOT_FOUND"
        }
    }

    if ($record.PurgeAllowed -or $record.ReuseAllowed -or $record.MutationAllowed) {
        return [pscustomobject]@{
            Allowed = $false
            Decision = "BLOCK"
            Code = "GUARD_STATE_INVALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "PURGE_REUSE_GUARD_VALID"
    }
}

function Test-EvidencePurgeReuseIntegrity {
    $records = @(Get-EvidencePurgeReuseRecords)

    foreach ($record in $records) {
        $expectedRegistration = Get-EvidencePurgeReuseHash (Get-PurgeReuseRegistrationCanonical -Record $record)
        $expectedState = Get-EvidencePurgeReuseHash (Get-PurgeReuseStateCanonical -Record $record)

        if ([string]$record.RegistrationHash -ne $expectedRegistration) {
            return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="REGISTRATION_INTEGRITY_INVALID"}
        }

        if ([string]$record.StateHash -ne $expectedState) {
            return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="STATE_INTEGRITY_INVALID"}
        }

        if ([bool]$record.PurgeAllowed -or [bool]$record.ReuseAllowed -or [bool]$record.MutationAllowed) {
            return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="FORBIDDEN_CAPABILITY_ENABLED"}
        }
    }

    return [pscustomobject]@{Allowed=$true;Decision="BLOCK";Code="PURGE_REUSE_INTEGRITY_VALID"}
}

function Test-EvidencePurgeReuseScope {
    param(
        [Parameter(Mandatory)][string]$GuardId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$ExecutionId
    )

    $record = Find-EvidencePurgeReuseRecord -GuardId $GuardId

    if ($null -eq $record) {
        return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="GUARD_NOT_FOUND"}
    }

    if ($record.TenantId -ne $TenantId) { return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_TENANT_PURGE_REUSE"} }
    if ($record.ClientId -ne $ClientId) { return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_CLIENT_PURGE_REUSE"} }
    if ($record.ProjectId -ne $ProjectId) { return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_PROJECT_PURGE_REUSE"} }
    if ($record.ExecutionId -ne $ExecutionId) { return [pscustomobject]@{Allowed=$false;Decision="BLOCK";Code="CROSS_EXECUTION_PURGE_REUSE"} }

    return [pscustomobject]@{Allowed=$true;Decision="BLOCK";Code="PURGE_REUSE_SCOPE_VALID"}
}

function Reset-EvidencePurgeReuse {
    Save-EvidencePurgeReuseRecords
}
