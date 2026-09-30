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
        foreach ($key in $InputObject.Keys) {
            $h[$key] = Convert-ToPlainHashtable $InputObject[$key]
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

function Get-RecoveryClosureConfig {
    $path = Join-Path $PSScriptRoot "config.json"
    return Get-Content -Raw -Path $path | ConvertFrom-Json
}

function Get-RecoveryClosureField {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    $cfg = Get-RecoveryClosureConfig
    $prop = $cfg.PSObject.Properties[$Name]

    if ($null -eq $prop) {
        return $null
    }

    return $prop.Value
}

function Get-RecoveryClosureState {
    $path = Join-Path $PSScriptRoot "state\closure-records.json"

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

function Save-RecoveryClosureState {
    param(
        [Parameter(Mandatory=$false)]
        $Records
    )

    $path = Join-Path $PSScriptRoot "state\closure-records.json"

    $safeRecords = @($Records)

    $json = ConvertTo-Json `
        -InputObject $safeRecords `
        -Depth 100

    [System.IO.File]::WriteAllText(
        $path,
        $json,
        [System.Text.Encoding]::UTF8
    )

    return $true
}

function Get-RecoveryClosureRecord {
    param(
        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ClosureId
    )

    if ([string]::IsNullOrWhiteSpace($ClosureId)) {
        return $null
    }

    $records = Get-RecoveryClosureState

    foreach ($record in $records) {
        if ($record.ClosureId -eq $ClosureId) {
            return $record
        }
    }

    return $null
}

function Test-RecoveryClosureConsistency {
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
        [string]$ConsistencyState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId
    )

    $cfg = Get-RecoveryClosureConfig

    if (-not $cfg.enabled -or -not $cfg.closureGuardEnabled) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_DISABLED"
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
                Status  = "BLOCKED"
                Reason  = "CONTEXT_INCOMPLETE"
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($RecoveryId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "RECOVERY_ID_REQUIRED"
        }
    }

    if ([string]::IsNullOrWhiteSpace($AuthorizationId)) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "AUTHORIZATION_ID_REQUIRED"
        }
    }

    if ($cfg.requireRecoveryAuthorization) {
        if ($AuthorizationState -ne "AUTHORIZED") {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "RECOVERY_NOT_AUTHORIZED"
            }
        }
    }

    if ($cfg.requireRecoveryConsistency) {
        if ($ConsistencyState -ne "CONSISTENT") {
            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "RECOVERY_INCONSISTENT"
            }
        }
    }

    if ($RecoveryState -ne "RECOVERED" -and
        $RecoveryState -ne "READY_FOR_FINALIZATION") {

        return [pscustomobject]@{
            Success = $false
            Status = "BLOCKED"
            Reason = "RECOVERY_STATE_INVALID"
        }
    }

    if ($cfg.requireFinalization) {
        if ($FinalizationState -ne "FINALIZED") {
            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "FINALIZATION_REQUIRED"
            }
        }

        if ([string]::IsNullOrWhiteSpace($FinalizationId)) {
            return [pscustomobject]@{
                Success = $false
                Status = "BLOCKED"
                Reason = "FINALIZATION_ID_REQUIRED"
            }
        }
    }

    $records = Get-RecoveryClosureState

    foreach ($record in $records) {

        if ($record.DeliveryId -eq $DeliveryId -and
            $record.ExecutionId -eq $ExecutionId -and
            $record.RecoveryId -eq $RecoveryId) {

            return [pscustomobject]@{
                Success      = $false
                Status       = "DUPLICATE"
                Reason       = "CLOSURE_ALREADY_EXISTS"
                ClosureId    = $record.ClosureId
            }
        }
    }

    return [pscustomobject]@{
        Success = $true
        Status  = "AUTHORIZED"
        Reason  = "RECOVERY_CLOSURE_ALLOWED"
    }
}

function Close-DeliveryRecovery {
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
        [string]$RecoveryState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$AuthorizationState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$ConsistencyState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationState,

        [Parameter(Mandatory=$false)]
        [AllowEmptyString()]
        [string]$FinalizationId
    )

    $check = Test-RecoveryClosureConsistency `
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
        -ConsistencyState $ConsistencyState `
        -FinalizationState $FinalizationState `
        -FinalizationId $FinalizationId

    if (-not $check.Success) {
        return $check
    }

    if ([string]::IsNullOrWhiteSpace($ClosureId)) {
        $ClosureId = [guid]::NewGuid().ToString()
    }

    $cfg = Get-RecoveryClosureConfig
    $records = Get-RecoveryClosureState

    if ($records.Count -ge [int]$cfg.maxClosures) {
        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "CLOSURE_LIMIT_REACHED"
        }
    }

    $record = [pscustomobject]@{
        ClosureId         = $ClosureId
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
        FinalizationState = $FinalizationState
        FinalizationId    = $FinalizationId
        Status             = "CLOSED"
        ClosedAtUtc        = [DateTime]::UtcNow.ToString("o")
    }

    $records = @($records) + $record

    $null = Save-RecoveryClosureState $records

    return [pscustomobject]@{
        Success      = $true
        Status       = "CLOSED"
        Reason       = "RECOVERY_CLOSED"
        ClosureId    = $ClosureId
        DeliveryId   = $DeliveryId
        ExecutionId  = $ExecutionId
        TenantId     = $TenantId
        ClientId     = $ClientId
        ProjectId    = $ProjectId
        LeaseId      = $LeaseId
        RecoveryId   = $RecoveryId
        AuthorizationId = $AuthorizationId
        FinalizationId  = $FinalizationId
    }
}

function Reset-RecoveryClosures {
    $null = Save-RecoveryClosureState @()
    return $true
}