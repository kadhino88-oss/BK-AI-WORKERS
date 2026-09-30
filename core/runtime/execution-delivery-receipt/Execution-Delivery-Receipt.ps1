Set-StrictMode -Version 2.0

function Get-DeliveryReceiptConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryReceiptState {

    $StateFile = Join-Path $PSScriptRoot "state\delivery-receipts.json"

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

function Save-DeliveryReceiptState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\delivery-receipts.json"

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

function New-DeliveryReceipt {

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

    return [pscustomobject][ordered]@{
        ReceiptId      = [guid]::NewGuid().ToString("N")
        DeliveryId     = $DeliveryId
        ExecutionId    = $ExecutionId
        TenantId       = $TenantId
        ClientId       = $ClientId
        ProjectId      = $ProjectId
        TargetId       = $TargetId
        Channel        = $Channel
        ConfirmedAtUtc = [DateTime]::UtcNow.ToString("o")
        Status         = "CONFIRMED"
    }
}

function Find-DeliveryReceipt {

    param(
        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$DeliveryId
    )

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return $null
    }

    $Records = @(Get-DeliveryReceiptState)

    $Record = @(
        $Records |
        Where-Object {
            [string]$_.DeliveryId -eq $DeliveryId
        }
    ) | Select-Object -First 1

    if ($null -eq $Record) {
        return $null
    }

    return $Record
}

function Confirm-Delivery {

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

    $Config = Get-DeliveryReceiptConfig

    if ([bool]$Config.requireDeliveryId -and
        [string]::IsNullOrWhiteSpace($DeliveryId)) {

        return [pscustomobject]@{
            Success    = $false
            Status     = "BLOCKED"
            Confirmed  = $false
            Reason     = "DELIVERY_ID_MISSING"
        }
    }

    if ([bool]$Config.requireExecutionId -and
        [string]::IsNullOrWhiteSpace($ExecutionId)) {

        return [pscustomobject]@{
            Success    = $false
            Status     = "BLOCKED"
            Confirmed  = $false
            Reason     = "EXECUTION_ID_MISSING"
        }
    }

    if ([bool]$Config.requireTargetId -and
        [string]::IsNullOrWhiteSpace($TargetId)) {

        return [pscustomobject]@{
            Success    = $false
            Status     = "BLOCKED"
            Confirmed  = $false
            Reason     = "TARGET_ID_MISSING"
        }
    }

    $Existing = Find-DeliveryReceipt -DeliveryId $DeliveryId

    if ($null -ne $Existing) {

        if (-not [bool]$Config.allowDuplicateReceipt) {
            return [pscustomobject]@{
                Success    = $true
                Status     = "DUPLICATE"
                Confirmed  = $true
                Reason     = "DELIVERY_ALREADY_CONFIRMED"
            }
        }
    }

    $Records = @(Get-DeliveryReceiptState)

    if ($Records.Count -ge [int]$Config.maxReceipts) {

        return [pscustomobject]@{
            Success    = $false
            Status     = "BLOCKED"
            Confirmed  = $false
            Reason     = "MAX_RECEIPTS_REACHED"
        }
    }

    $Receipt = New-DeliveryReceipt `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -TargetId $TargetId `
        -Channel $Channel

    $Records += ,$Receipt

    $null = Save-DeliveryReceiptState -Records $Records

    return [pscustomobject]@{
        Success    = $true
        Status     = "CONFIRMED"
        Confirmed  = $true
        ReceiptId  = $Receipt.ReceiptId
        Reason     = "DELIVERY_CONFIRMED"
    }
}

function Test-DeliveryReceipt {

    param(
        [Parameter()]
        $Receipt,

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
        [string]$TargetId
    )

    if ($null -eq $Receipt) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "RECEIPT_NULL"
        }
    }

    if ([string]$Receipt.DeliveryId -ne $DeliveryId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "DELIVERY_ID_MISMATCH"
        }
    }

    if ([string]$Receipt.ExecutionId -ne $ExecutionId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([string]$Receipt.TenantId -ne $TenantId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "TENANT_MISMATCH"
        }
    }

    if ([string]$Receipt.ClientId -ne $ClientId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "CLIENT_MISMATCH"
        }
    }

    if ([string]$Receipt.ProjectId -ne $ProjectId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "PROJECT_MISMATCH"
        }
    }

    if ([string]$Receipt.TargetId -ne $TargetId) {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "TARGET_MISMATCH"
        }
    }

    if ([string]$Receipt.Status -ne "CONFIRMED") {
        return [pscustomobject]@{
            Valid  = $false
            Reason = "RECEIPT_NOT_CONFIRMED"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Reason = "RECEIPT_VALID"
    }
}

function Reset-DeliveryReceipts {

    $null = Save-DeliveryReceiptState -Records @()

    return
}