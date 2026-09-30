function Convert-ToCanonicalClosureContent {
    param(
        [Parameter(Mandatory=$false)]
        $Record
    )

    if ($null -eq $Record) {
        return ""
    }

    return (
        "{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}|{8}|{9}|{10}|{11}" -f
        [string]$Record.ClosureId,
        [string]$Record.DeliveryId,
        [string]$Record.ExecutionId,
        [string]$Record.TenantId,
        [string]$Record.ClientId,
        [string]$Record.ProjectId,
        [string]$Record.LeaseId,
        [string]$Record.RecoveryId,
        [string]$Record.AuthorizationId,
        [string]$Record.FinalizationId,
        [string]$Record.Status,
        [string]$Record.ClosedAtUtc
    )
}

function Get-SHA256Hash {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Content
    )

    $sha = New-Object System.Security.Cryptography.SHA256Managed

    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes(
            [string]$Content
        )

        return (
            [System.BitConverter]::ToString(
                $sha.ComputeHash($bytes)
            ) -replace "-", ""
        ).ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-ClosureIntegrityConfig {
    $path = Join-Path $PSScriptRoot "config.json"

    return (
        Get-Content -Raw -Path $path |
        ConvertFrom-Json
    )
}

function Get-ClosureIntegrityField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-ClosureIntegrityConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-ClosureIntegrityState {
    $path = Join-Path $PSScriptRoot "state\integrity-records.json"

    if (-not (Test-Path $path)) {
        return @()
    }

    $raw = Get-Content -Raw -Path $path

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return @()
    }

    $parsed = $raw | ConvertFrom-Json

    if ($null -eq $parsed) {
        return @()
    }

    return @($parsed)
}

function Save-ClosureIntegrityState {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\integrity-records.json"

    $safe = @($Records)

    $json = ConvertTo-Json `
        -InputObject $safe `
        -Depth 100

    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.Encoding]::UTF8
    )

    return $true
}

function Get-ClosureIntegrityRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId
    )

    if ([string]::IsNullOrWhiteSpace($ClosureId)) {
        return $null
    }

    $records = Get-ClosureIntegrityState

    foreach ($record in $records) {
        if ($record.ClosureId -eq $ClosureId) {
            return $record
        }
    }

    return $null
}

function Test-ClosureIntegrity {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$LeaseId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RecoveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Status,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosedAtUtc,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ExpectedHash
    )

    $cfg = Get-ClosureIntegrityConfig

    if (-not $cfg.enabled -or -not $cfg.integrityGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "INTEGRITY_GUARD_DISABLED"
        }
    }

    if ($cfg.requireClosureId) {
        if ([string]::IsNullOrWhiteSpace($ClosureId)) {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CLOSURE_ID_REQUIRED"
            }
        }
    }

    if ($cfg.requireDeliveryContext) {
        if ([string]::IsNullOrWhiteSpace($DeliveryId) -or
            [string]::IsNullOrWhiteSpace($ExecutionId) -or
            [string]::IsNullOrWhiteSpace($TenantId) -or
            [string]::IsNullOrWhiteSpace($ClientId) -or
            [string]::IsNullOrWhiteSpace($ProjectId) -or
            [string]::IsNullOrWhiteSpace($LeaseId) -or
            [string]::IsNullOrWhiteSpace($RecoveryId) -or
            [string]::IsNullOrWhiteSpace($AuthorizationId) -or
            [string]::IsNullOrWhiteSpace($FinalizationId)) {

            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CONTEXT_INCOMPLETE"
            }
        }
    }

    if ($Status -ne "CLOSED") {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_STATUS_INVALID"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClosedAtUtc)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSED_TIMESTAMP_REQUIRED"
        }
    }

    $record = [pscustomobject]@{
        ClosureId        = $ClosureId
        DeliveryId       = $DeliveryId
        ExecutionId      = $ExecutionId
        TenantId         = $TenantId
        ClientId         = $ClientId
        ProjectId        = $ProjectId
        LeaseId          = $LeaseId
        RecoveryId       = $RecoveryId
        AuthorizationId  = $AuthorizationId
        FinalizationId   = $FinalizationId
        Status           = $Status
        ClosedAtUtc      = $ClosedAtUtc
    }

    $canonical = Convert-ToCanonicalClosureContent $record
    $actualHash = Get-SHA256Hash $canonical

    if (-not [string]::IsNullOrWhiteSpace($ExpectedHash)) {
        if ($actualHash -ne $ExpectedHash.ToLowerInvariant()) {
            return [pscustomobject]@{
                Success     = $false
                Status      = "BLOCKED"
                Reason      = "INTEGRITY_MISMATCH"
                ActualHash  = $actualHash
                ExpectedHash= $ExpectedHash.ToLowerInvariant()
            }
        }
    }

    return [pscustomobject]@{
        Success     = $true
        Status      = "VALID"
        Reason      = "CLOSURE_INTEGRITY_VALID"
        ClosureHash = $actualHash
    }
}

function Register-ClosureIntegrity {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$LeaseId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RecoveryId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Status,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosedAtUtc
    )

    $check = Test-ClosureIntegrity `
        -ClosureId $ClosureId `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -LeaseId $LeaseId `
        -RecoveryId $RecoveryId `
        -AuthorizationId $AuthorizationId `
        -FinalizationId $FinalizationId `
        -Status $Status `
        -ClosedAtUtc $ClosedAtUtc

    if (-not $check.Success) {
        return $check
    }

    $cfg = Get-ClosureIntegrityConfig
    $records = Get-ClosureIntegrityState

    foreach ($record in $records) {
        if ($record.ClosureId -eq $ClosureId) {
            return [pscustomobject]@{
                Success      = $false
                Status       = "DUPLICATE"
                Reason       = "INTEGRITY_RECORD_ALREADY_EXISTS"
                ClosureId    = $ClosureId
            }
        }
    }

    if ($records.Count -ge [int]$cfg.maxRecords) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "INTEGRITY_RECORD_LIMIT_REACHED"
        }
    }

    $record = [pscustomobject]@{
        IntegrityId      = [guid]::NewGuid().ToString()
        ClosureId        = $ClosureId
        DeliveryId       = $DeliveryId
        ExecutionId      = $ExecutionId
        TenantId         = $TenantId
        ClientId         = $ClientId
        ProjectId        = $ProjectId
        LeaseId          = $LeaseId
        RecoveryId       = $RecoveryId
        AuthorizationId  = $AuthorizationId
        FinalizationId   = $FinalizationId
        Status           = $Status
        ClosedAtUtc      = $ClosedAtUtc
        ClosureHash      = $check.ClosureHash
        RecordedAtUtc    = [DateTime]::UtcNow.ToString("o")
    }

    $records = @($records) + $record
    $null = Save-ClosureIntegrityState $records

    return $record
}

function Test-ClosedClosureReopen {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId,

        [Parameter(Mandatory=$false)]
        [bool]$ExplicitReopen = $false
    )

    $cfg = Get-ClosureIntegrityConfig

    if (-not $cfg.enabled -or -not $cfg.reopenGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "REOPEN_GUARD_DISABLED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ClosureId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_ID_REQUIRED"
        }
    }

    $record = Get-ClosureIntegrityRecord -ClosureId $ClosureId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_NOT_FOUND"
        }
    }

    if ($record.Status -eq "CLOSED") {

        if ($cfg.preventImplicitReopen -and -not $ExplicitReopen) {
            return [pscustomobject]@{
                Success   = $false
                Status    = "BLOCKED"
                Reason    = "IMPLICIT_REOPEN_BLOCKED"
            }
        }

        if (-not $cfg.allowExplicitReopen -and $ExplicitReopen) {
            return [pscustomobject]@{
                Success   = $false
                Status    = "BLOCKED"
                Reason    = "EXPLICIT_REOPEN_DISABLED"
            }
        }

        return [pscustomobject]@{
            Success = $true
            Status  = "REOPEN_ALLOWED"
            Reason  = "EXPLICIT_REOPEN_ALLOWED"
        }
    }

    return [pscustomobject]@{
        Success = $false
        Status  = "BLOCKED"
        Reason  = "CLOSURE_STATE_INVALID"
    }
}

function Test-ClosedClosureMutation {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$RequestedStatus
    )

    $record = Get-ClosureIntegrityRecord -ClosureId $ClosureId

    if ($null -eq $record) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_NOT_FOUND"
        }
    }

    if ($record.Status -eq "CLOSED") {

        if ($RequestedStatus -ne "CLOSED") {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "CLOSED_STATE_MUTATION_BLOCKED"
            }
        }

        return [pscustomobject]@{
            Success = $true
            Status  = "UNCHANGED"
            Reason  = "CLOSED_STATE_UNCHANGED"
        }
    }

    return [pscustomobject]@{
        Success = $false
        Status  = "BLOCKED"
        Reason = "CLOSURE_STATE_INVALID"
    }
}

function Reset-ClosureIntegrity {
    $null = Save-ClosureIntegrityState @()
    return $true
}