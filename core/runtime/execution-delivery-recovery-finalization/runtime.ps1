function Convert-ToPlainHashtable {
    param(
        [Parameter(Mandatory=$false)]
        $InputObject
    )
    # PowerShell 7 convertit les dates ISO en [datetime] (recursion infinie via .Date) ;
    # Windows PowerShell 5.1 les laissait en texte : on renvoie le meme texte ISO.
    if ($InputObject -is [datetime]) { return $InputObject.ToString("o") }
    if ($InputObject -is [datetimeoffset]) { return $InputObject.ToString("o") }


    if ($null -eq $InputObject) {
        return $null
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $h = @{}
        foreach ($k in $InputObject.Keys) {
            $h[$k] = Convert-ToPlainHashtable $InputObject[$k]
        }
        return $h
    }

    if (($InputObject -is [System.Collections.IEnumerable]) -and
        -not ($InputObject -is [string])) {

        $arr = @()
        foreach ($item in $InputObject) {
            $arr += ,(Convert-ToPlainHashtable $item)
        }
        return $arr
    }

    if ($InputObject.PSObject -and
        -not ($InputObject -is [string]) -and
        -not ($InputObject.GetType().IsPrimitive) -and
        -not ($InputObject -is [datetime])) {

        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) {
            $h[$p.Name] = Convert-ToPlainHashtable $p.Value
        }
        return $h
    }

    return $InputObject
}

function Get-RecoveryFinalizationConfig {
    $path = Join-Path $PSScriptRoot "config.json"
    return Get-Content -Raw -Path $path | ConvertFrom-Json
}

function Get-RecoveryFinalizationField {
    param(
        [Parameter(Mandatory=$false)]
        $Name
    )

    $cfg = Get-RecoveryFinalizationConfig
    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $p = $cfg.PSObject.Properties[$Name]
    if ($null -eq $p) {
        return $null
    }

    return $p.Value
}

function Get-RecoveryFinalizationState {
    $path = Join-Path $PSScriptRoot "state\finalization-records.json"

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

function Save-RecoveryFinalizationState {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\finalization-records.json"
    $safe = @($Records)

    $json = ConvertTo-Json -InputObject $safe -Depth 100
    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.Encoding]::UTF8
    )

    return $true
}

function Get-RecoveryFinalizationRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId
    )

    if ([string]::IsNullOrWhiteSpace($FinalizationId)) {
        return $null
    }

    $records = Get-RecoveryFinalizationState

    foreach ($r in $records) {
        if ($r.FinalizationId -eq $FinalizationId) {
            return $r
        }
    }

    return $null
}

function Test-RecoveryFinalization {
    param(
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
        [string]$RecoveryState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ConsistencyState
    )

    $cfg = Get-RecoveryFinalizationConfig

    if (-not $cfg.enabled -or -not $cfg.finalizationEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "FINALIZATION_DISABLED"
        }
    }

    if ($cfg.requireDeliveryContext) {
        if ([string]::IsNullOrWhiteSpace($DeliveryId) -or
            [string]::IsNullOrWhiteSpace($ExecutionId) -or
            [string]::IsNullOrWhiteSpace($TenantId) -or
            [string]::IsNullOrWhiteSpace($ClientId) -or
            [string]::IsNullOrWhiteSpace($ProjectId) -or
            [string]::IsNullOrWhiteSpace($LeaseId)) {

            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "CONTEXT_INCOMPLETE"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($RecoveryId)) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "RECOVERY_ID_REQUIRED"
        }
    }

    if ($cfg.requireRecoveryAuthorization) {
        if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "AUTHORIZATION_ID_REQUIRED"
            }
        }

        if ($AuthorizationState -ne "AUTHORIZED") {
            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "RECOVERY_NOT_AUTHORIZED"
            }
        }
    }

    if ($cfg.requireRecoveryConsistency) {
        if ($ConsistencyState -ne "CONSISTENT") {
            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "RECOVERY_INCONSISTENT"
            }
        }
    }

    if ($RecoveryState -ne "RECOVERED" -and
        $RecoveryState -ne "READY_FOR_FINALIZATION") {

        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "RECOVERY_NOT_READY"
        }
    }

    $records = Get-RecoveryFinalizationState

    foreach ($r in $records) {
        if ($r.DeliveryId -eq $DeliveryId -and
            $r.ExecutionId -eq $ExecutionId -and
            $r.RecoveryId -eq $RecoveryId) {

            return [pscustomobject]@{
                Success = $false
                Status = "DUPLICATE"
                Reason = "FINALIZATION_ALREADY_EXISTS"
                FinalizationId = $r.FinalizationId
            }
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status = "AUTHORIZED"
        Reason = "RECOVERY_FINALIZATION_ALLOWED"
    }
}

function Finalize-DeliveryRecovery {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId,

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
        [string]$RecoveryState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ConsistencyState
    )

    $check = Test-RecoveryFinalization `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -LeaseId $LeaseId `
        -RecoveryId $RecoveryId `
        -AuthorizationId $AuthorizationId `
        -RecoveryState $RecoveryState `
        -AuthorizationState $AuthorizationState `
        -ConsistencyState $ConsistencyState

    if (-not $check.Success) {
        return $check
    }

    if ([string]::IsNullOrWhiteSpace($FinalizationId)) {
        $FinalizationId = [guid]::NewGuid().ToString()
    }

    $cfg = Get-RecoveryFinalizationConfig
    $records = Get-RecoveryFinalizationState

    if ($records.Count -ge [int]$cfg.maxFinalizations) {
        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "FINALIZATION_LIMIT_REACHED"
        }
    }

    $record = [pscustomobject]@{
        FinalizationId    = $FinalizationId
        DeliveryId        = $DeliveryId
        ExecutionId       = $ExecutionId
        TenantId          = $TenantId
        ClientId          = $ClientId
        ProjectId         = $ProjectId
        LeaseId           = $LeaseId
        RecoveryId        = $RecoveryId
        AuthorizationId   = $AuthorizationId
        RecoveryState     = $RecoveryState
        AuthorizationState= $AuthorizationState
        ConsistencyState  = $ConsistencyState
        Status            = "FINALIZED"
        FinalizedAtUtc    = [DateTime]::UtcNow.ToString("o")
    }

    $records = @($records) + $record
    $null = Save-RecoveryFinalizationState $records

    return [pscustomobject]@{
        Success = $true
        Status = "FINALIZED"
        Reason = "RECOVERY_FINALIZED"
        FinalizationId = $FinalizationId
        DeliveryId = $DeliveryId
        ExecutionId = $ExecutionId
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        LeaseId = $LeaseId
        RecoveryId = $RecoveryId
        AuthorizationId = $AuthorizationId
    }
}

function Reset-RecoveryFinalization {
    $null = Save-RecoveryFinalizationState @()
    return $true
}