Set-StrictMode -Version 2.0

function Get-DeliveryIdempotencyConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryIdempotencyState {

    $StateFile = Join-Path $PSScriptRoot "state\delivery-records.json"

    if (-not (Test-Path $StateFile)) {
        return @()
    }

    $Raw = Get-Content -Raw -Path $StateFile

    if ([string]::IsNullOrWhiteSpace($Raw)) {
        return @()
    }

    $Parsed = ConvertFrom-Json $Raw

    if ($null -eq $Parsed) {
        return @()
    }

    return @($Parsed)
}

function Save-DeliveryIdempotencyState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\delivery-records.json"

    $Array = @($Records)

    if ($Array.Count -eq 0) {
        [System.IO.File]::WriteAllText(
            $StateFile,
            "[]",
            [System.Text.UTF8Encoding]::new($false)
        )

        return
    }

    $Json = ConvertTo-Json -InputObject $Array -Depth 20

    [System.IO.File]::WriteAllText(
        $StateFile,
        $Json,
        [System.Text.UTF8Encoding]::new($false)
    )

    return
}

function Get-DeliveryIdempotencyKey {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TargetId
    )

    return (
        [string]$DeliveryId + "|" +
        [string]$ExecutionId + "|" +
        [string]$TargetId
    ).ToLowerInvariant()
}

function Test-DeliveryDuplicate {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TargetId
    )

    $Key = Get-DeliveryIdempotencyKey `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TargetId $TargetId

    $Records = @(Get-DeliveryIdempotencyState)

    foreach ($Record in $Records) {

        if ([string]$Record.IdempotencyKey -eq $Key) {

            return [pscustomobject]@{
                Duplicate = $true
                Status    = "DUPLICATE"
                Reason    = "DELIVERY_ALREADY_REGISTERED"
            }
        }
    }

    return [pscustomobject]@{
        Duplicate = $false
        Status    = "NEW"
        Reason    = "DELIVERY_NOT_REGISTERED"
    }
}

function Register-DeliveryAttempt {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ExecutionId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TenantId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ClientId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$ProjectId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TargetId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Channel
    )

    $Config = Get-DeliveryIdempotencyConfig

    if ([bool]$Config.requireDeliveryId) {

        if ([string]::IsNullOrWhiteSpace($DeliveryId)) {

            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "DELIVERY_ID_MISSING"
            }
        }
    }

    if ([bool]$Config.requireExecutionId) {

        if ([string]::IsNullOrWhiteSpace($ExecutionId)) {

            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "EXECUTION_ID_MISSING"
            }
        }
    }

    if ([bool]$Config.requireTargetId) {

        if ([string]::IsNullOrWhiteSpace($TargetId)) {

            return [pscustomobject]@{
                Success = $false
                Status  = "BLOCKED"
                Reason  = "TARGET_ID_MISSING"
            }
        }
    }

    $Duplicate = Test-DeliveryDuplicate `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TargetId $TargetId

    if ($Duplicate.Duplicate) {

        return [pscustomobject]@{
            Success = $true
            Status  = "DUPLICATE"
            Reason  = "DELIVERY_ALREADY_REGISTERED"
        }
    }

    $Records = @(Get-DeliveryIdempotencyState)

    if ($Records.Count -ge [int]$Config.maxRecords) {

        return [pscustomobject]@{
            Success = $false
            Status  = "BLOCKED"
            Reason  = "MAX_RECORDS_REACHED"
        }
    }

    $Key = Get-DeliveryIdempotencyKey `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TargetId $TargetId

    $Record = [pscustomobject][ordered]@{
        IdempotencyKey  = $Key
        DeliveryId      = $DeliveryId
        ExecutionId     = $ExecutionId
        TenantId        = $TenantId
        ClientId        = $ClientId
        ProjectId       = $ProjectId
        TargetId        = $TargetId
        Channel         = $Channel
        RegisteredAtUtc = [DateTime]::UtcNow.ToString("o")
        Status          = "REGISTERED"
    }

    $Records += ,$Record

    $null = Save-DeliveryIdempotencyState -Records $Records

    return [pscustomobject]@{
        Success = $true
        Status  = "REGISTERED"
        Reason  = "DELIVERY_REGISTERED"
    }
}

function Reset-DeliveryIdempotency {

    $null = Save-DeliveryIdempotencyState -Records @()

    return
}