function Get-FinalRevocationConfig {

    $path = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path -LiteralPath $path)) {
        throw "REVOCATION_CONFIG_MISSING"
    }

    $raw = Get-Content -LiteralPath $path -Raw

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "REVOCATION_CONFIG_EMPTY"
    }

    return $raw | ConvertFrom-Json
}

function Get-FinalRevocationRecords {

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

    return @($data)
}

function Save-FinalRevocationRecords {

    param(
        [AllowEmptyCollection()]
        [object[]]$Records = @()
    )

    $config = Get-FinalRevocationConfig
    $path = Join-Path $PSScriptRoot "state\records.json"

    if ($Records.Count -gt [int]$config.maxRecords) {
        throw "REVOCATION_RECORD_LIMIT"
    }

    if ($Records.Count -eq 0) {

        Set-Content `
            -LiteralPath $path `
            -Value "[]" `
            -Encoding UTF8

        return
    }

    $json = ConvertTo-Json `
        -InputObject @($Records) `
        -Depth 30

    Set-Content `
        -LiteralPath $path `
        -Value $json `
        -Encoding UTF8
}

function Get-FinalRevocationHash {

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

function New-RevocationEventId {

    return "REV-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
}

function Register-FinalEnforcement {

    param(
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$RecoveryId,
        [Parameter(Mandatory)][string]$ConsumptionId,
        [Parameter(Mandatory)][string]$AuthorizationId,
        [Parameter(Mandatory)][string]$ExecutionId,
        [Parameter(Mandatory)][string]$TenantId,
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$ProjectId,
        [Parameter(Mandatory)][string]$UserId,
        [Parameter(Mandatory)][string]$WorkerId
    )

    $config = Get-FinalRevocationConfig

    if (-not $config.enabled) {
        throw "REVOCATION_GUARD_DISABLED"
    }

    $required = @(
        $EnforcementId
        $RecoveryId
        $ConsumptionId
        $AuthorizationId
        $ExecutionId
        $TenantId
        $ClientId
        $ProjectId
        $UserId
        $WorkerId
    )

    foreach ($value in $required) {

        if ([string]::IsNullOrWhiteSpace($value)) {
            throw "REVOCATION_BINDING_REQUIRED"
        }
    }

    $records = @(Get-FinalRevocationRecords)

    foreach ($existing in $records) {

        if ($existing.EnforcementId -eq $EnforcementId) {
            throw "ENFORCEMENT_ALREADY_REGISTERED"
        }
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")

    $canonical = (
        $EnforcementId + "|" +
        $RecoveryId + "|" +
        $ConsumptionId + "|" +
        $AuthorizationId + "|" +
        $ExecutionId + "|" +
        $TenantId + "|" +
        $ClientId + "|" +
        $ProjectId + "|" +
        $UserId + "|" +
        $WorkerId + "|" +
        $now
    )

    $hash = Get-FinalRevocationHash -Value $canonical

    $record = [pscustomobject][ordered]@{
        EnforcementId        = $EnforcementId
        RecoveryId           = $RecoveryId
        ConsumptionId        = $ConsumptionId
        AuthorizationId      = $AuthorizationId
        ExecutionId          = $ExecutionId
        TenantId             = $TenantId
        ClientId             = $ClientId
        ProjectId            = $ProjectId
        UserId               = $UserId
        WorkerId             = $WorkerId

        IntegrityHash        = $hash

        EnforcementStatus    = "ACTIVE"
        ConsumptionStatus    = "AUTHORIZED"
        AuthorizationStatus  = "AUTHORIZED"
        ExecutionStatus      = "AUTHORIZED"

        RevocationStatus     = "NOT_REVOKED"
        KillSwitchActive     = $false

        ReactivationAllowed  = $false
        ReopenAllowed        = $false

        Decision             = "ALLOW"

        CreatedAtUtc         = $now

        RevokedAtUtc         = $null
        RevocationReason     = $null
        RevocationActor      = $null
        RevocationEventId    = $null
        RevocationHash       = $null

        RawSecret            = $null
        RawCredential        = $null
    }

    $records += $record

    Save-FinalRevocationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "FINAL_ENFORCEMENT_REGISTERED"
        EnforcementId = $EnforcementId
    }
}

function Revoke-FinalEnforcement {

    param(
        [Parameter(Mandatory)][string]$EnforcementId,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter(Mandatory)][string]$Actor
    )

    $config = Get-FinalRevocationConfig

    if (-not $config.revocationEnabled) {
        throw "REVOCATION_DISABLED"
    }

    if (-not $config.killSwitchEnabled) {
        throw "KILL_SWITCH_DISABLED"
    }

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        throw "REVOCATION_REASON_REQUIRED"
    }

    if ([string]::IsNullOrWhiteSpace($Actor)) {
        throw "REVOCATION_ACTOR_REQUIRED"
    }

    $records = @(Get-FinalRevocationRecords)

    $target = $null
    $targetIndex = -1

    for ($i = 0; $i -lt $records.Count; $i++) {

        if ($records[$i].EnforcementId -eq $EnforcementId) {

            $target = $records[$i]
            $targetIndex = $i
            break
        }
    }

    if ($null -eq $target) {
        throw "ENFORCEMENT_NOT_FOUND"
    }

    if ($target.RevocationStatus -eq "REVOKED") {
        throw "ALREADY_REVOKED"
    }

    $now = (Get-Date).ToUniversalTime().ToString("o")
    $eventId = New-RevocationEventId

    # Tous les champs existent déjà sur l'objet.
    # On modifie uniquement les valeurs.

    $target.EnforcementStatus = "REVOKED"
    $target.ConsumptionStatus = "REVOKED"
    $target.AuthorizationStatus = "REVOKED"
    $target.ExecutionStatus = "BLOCKED"

    $target.RevocationStatus = "REVOKED"
    $target.KillSwitchActive = $true

    $target.ReactivationAllowed = $false
    $target.ReopenAllowed = $false
    $target.Decision = "BLOCK"

    $target.RevokedAtUtc = $now
    $target.RevocationReason = $Reason
    $target.RevocationActor = $Actor
    $target.RevocationEventId = $eventId

    $revocationCanonical = (
        $eventId + "|" +
        $EnforcementId + "|" +
        $target.RecoveryId + "|" +
        $target.ConsumptionId + "|" +
        $target.AuthorizationId + "|" +
        $target.ExecutionId + "|" +
        $Reason + "|" +
        $Actor + "|" +
        $now
    )

    $target.RevocationHash = Get-FinalRevocationHash `
        -Value $revocationCanonical

    $records[$targetIndex] = $target

    Save-FinalRevocationRecords -Records $records

    return [pscustomobject]@{
        Allowed = $true
        Decision = "BLOCK"
        Code = "REVOCATION_CASCADE_APPLIED"
        EnforcementId = $EnforcementId
        KillSwitchActive = $true
        RevocationEventId = $eventId
    }
}

function Test-FinalEnforcementRevocation {

    param(
        [Parameter(Mandatory)]
        [string]$EnforcementId
    )

    $records = @(Get-FinalRevocationRecords)

    foreach ($record in $records) {

        if ($record.EnforcementId -eq $EnforcementId) {

            if ($record.RevocationStatus -eq "REVOKED") {

                return [pscustomobject]@{
                    Allowed = $false
                    Decision = "BLOCK"
                    Code = "FINAL_ENFORCEMENT_REVOKED"
                    KillSwitchActive = $record.KillSwitchActive
                }
            }

            return [pscustomobject]@{
                Allowed = $true
                Decision = "ALLOW"
                Code = "FINAL_ENFORCEMENT_ACTIVE"
                KillSwitchActive = $false
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "ENFORCEMENT_NOT_FOUND"
    }
}

function Test-RevocationCascadeIntegrity {

    $records = @(Get-FinalRevocationRecords)

    foreach ($record in $records) {

        if ($record.RevocationStatus -ne "REVOKED") {
            continue
        }

        if ($record.EnforcementStatus -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "ENFORCEMENT_REVOCATION_MISMATCH"
            }
        }

        if ($record.ConsumptionStatus -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "CONSUMPTION_REVOCATION_MISMATCH"
            }
        }

        if ($record.AuthorizationStatus -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "AUTHORIZATION_REVOCATION_MISMATCH"
            }
        }

        if ($record.ExecutionStatus -ne "BLOCKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "EXECUTION_NOT_BLOCKED"
            }
        }

        if ($record.KillSwitchActive -ne $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "KILL_SWITCH_NOT_ACTIVE"
            }
        }

        if ($record.ReactivationAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REACTIVATION_ALLOWED"
            }
        }

        if ($record.ReopenAllowed -eq $true) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REOPEN_ALLOWED"
            }
        }

        if ([string]::IsNullOrWhiteSpace($record.RevocationReason)) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REVOCATION_REASON_MISSING"
            }
        }

        if ([string]::IsNullOrWhiteSpace($record.RevocationActor)) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REVOCATION_ACTOR_MISSING"
            }
        }

        if ([string]::IsNullOrWhiteSpace($record.RevocationEventId)) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REVOCATION_EVENT_MISSING"
            }
        }

        if ([string]::IsNullOrWhiteSpace($record.RevocationHash)) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REVOCATION_HASH_MISSING"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $true
        Decision = "ALLOW"
        Code = "REVOCATION_CASCADE_INTEGRITY_VALID"
    }
}

function Test-RevokedExecution {

    param(
        [Parameter(Mandatory)]
        [string]$EnforcementId,

        [Parameter(Mandatory)]
        [string]$ExecutionId
    )

    $records = @(Get-FinalRevocationRecords)

    foreach ($record in $records) {

        if (
            ($record.EnforcementId -eq $EnforcementId) -and
            ($record.ExecutionId -eq $ExecutionId)
        ) {

            if (
                ($record.RevocationStatus -eq "REVOKED") -or
                ($record.ExecutionStatus -eq "BLOCKED") -or
                ($record.KillSwitchActive -eq $true)
            ) {

                return [pscustomobject]@{
                    Allowed = $false
                    Decision = "BLOCK"
                    Code = "EXECUTION_KILLED"
                }
            }

            return [pscustomobject]@{
                Allowed = $true
                Decision = "ALLOW"
                Code = "EXECUTION_ACTIVE"
            }
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "EXECUTION_NOT_FOUND"
    }
}

function Test-RevocationEventIntegrity {

    param(
        [Parameter(Mandatory)]
        [string]$EnforcementId
    )

    $records = @(Get-FinalRevocationRecords)

    foreach ($record in $records) {

        if ($record.EnforcementId -ne $EnforcementId) {
            continue
        }

        if ($record.RevocationStatus -ne "REVOKED") {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "NOT_REVOKED"
            }
        }

        $canonical = (
            $record.RevocationEventId + "|" +
            $record.EnforcementId + "|" +
            $record.RecoveryId + "|" +
            $record.ConsumptionId + "|" +
            $record.AuthorizationId + "|" +
            $record.ExecutionId + "|" +
            $record.RevocationReason + "|" +
            $record.RevocationActor + "|" +
            $record.RevokedAtUtc
        )

        $expectedHash = Get-FinalRevocationHash `
            -Value $canonical

        if ($record.RevocationHash -ne $expectedHash) {

            return [pscustomobject]@{
                Allowed = $false
                Decision = "BLOCK"
                Code = "REVOCATION_HASH_INVALID"
            }
        }

        return [pscustomobject]@{
            Allowed = $true
            Decision = "ALLOW"
            Code = "REVOCATION_EVENT_INTEGRITY_VALID"
        }
    }

    return [pscustomobject]@{
        Allowed = $false
        Decision = "BLOCK"
        Code = "ENFORCEMENT_NOT_FOUND"
    }
}

function Reset-FinalRevocation {

    Save-FinalRevocationRecords
}
