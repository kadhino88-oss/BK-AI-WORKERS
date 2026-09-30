Set-StrictMode -Version 2.0

function Get-DeliveryCompletionConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-DeliveryCompletionState {

    $StateFile = Join-Path $PSScriptRoot "state\completion-records.json"

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

function Save-DeliveryCompletionState {

    param(
        [Parameter(Mandatory=$true)]
        $Records
    )

    $StateFile = Join-Path $PSScriptRoot "state\completion-records.json"

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

function Test-DeliveryCompletion {

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

    $Config = Get-DeliveryCompletionConfig

    if ([bool]$Config.requireConfirmedReceipt) {

        if ($null -eq $Receipt) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "RECEIPT_REQUIRED"
            }
        }

        if ([string]$Receipt.Status -ne "CONFIRMED") {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "RECEIPT_NOT_CONFIRMED"
            }
        }
    }

    if ([bool]$Config.requireExecutionId) {
        if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "EXECUTION_ID_MISSING"
            }
        }

        if ([string]$Receipt.ExecutionId -ne $ExecutionId) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "EXECUTION_ID_MISMATCH"
            }
        }
    }

    if ([bool]$Config.requireTenantId) {
        if ([string]::IsNullOrWhiteSpace($TenantId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "TENANT_ID_MISSING"
            }
        }

        if ([string]$Receipt.TenantId -ne $TenantId) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "TENANT_MISMATCH"
            }
        }
    }

    if ([bool]$Config.requireClientId) {
        if ([string]::IsNullOrWhiteSpace($ClientId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "CLIENT_ID_MISSING"
            }
        }

        if ([string]$Receipt.ClientId -ne $ClientId) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "CLIENT_MISMATCH"
            }
        }
    }

    if ([bool]$Config.requireProjectId) {
        if ([string]::IsNullOrWhiteSpace($ProjectId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "PROJECT_ID_MISSING"
            }
        }

        if ([string]$Receipt.ProjectId -ne $ProjectId) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "PROJECT_MISMATCH"
            }
        }
    }

    if ([bool]$Config.requireTargetId) {
        if ([string]::IsNullOrWhiteSpace($TargetId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "TARGET_ID_MISSING"
            }
        }

        if ([string]$Receipt.TargetId -ne $TargetId) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "TARGET_MISMATCH"
            }
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "VALID"
        Reason = "COMPLETION_ALLOWED"
    }
}

function Complete-Delivery {

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

    $Config = Get-DeliveryCompletionConfig

    if ([string]::IsNullOrWhiteSpace($DeliveryId)) {
        return [pscustomobject]@{
            Success    = $false
            Completed  = $false
            Status     = "BLOCKED"
            Reason     = "DELIVERY_ID_MISSING"
        }
    }

    $Validation = Test-DeliveryCompletion `
        -Receipt $Receipt `
        -DeliveryId $DeliveryId `
        -ExecutionId $ExecutionId `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -TargetId $TargetId

    if (-not $Validation.Valid) {
        return [pscustomobject]@{
            Success    = $false
            Completed  = $false
            Status     = "BLOCKED"
            Reason     = $Validation.Reason
        }
    }

    $Records = @(Get-DeliveryCompletionState)

    if ([bool]$Config.preventDuplicateCompletion) {

        foreach ($Record in $Records) {
            if ([string]$Record.DeliveryId -eq $DeliveryId) {

                return [pscustomobject]@{
                    Success    = $true
                    Completed  = $true
                    Status     = "DUPLICATE"
                    CompletionId = [string]$Record.CompletionId
                    Reason     = "DELIVERY_ALREADY_COMPLETED"
                }
            }
        }
    }

    $Completion = [pscustomobject][ordered]@{
        CompletionId   = [guid]::NewGuid().ToString("N")
        DeliveryId     = $DeliveryId
        ExecutionId    = $ExecutionId
        TenantId       = $TenantId
        ClientId       = $ClientId
        ProjectId      = $ProjectId
        TargetId       = $TargetId
        CompletedAtUtc = [DateTime]::UtcNow.ToString("o")
        Status         = "COMPLETED"
    }

    $Records += ,$Completion

    $null = Save-DeliveryCompletionState -Records $Records

    return [pscustomobject]@{
        Success      = $true
        Completed    = $true
        Status       = "COMPLETED"
        CompletionId = $Completion.CompletionId
        Reason       = "DELIVERY_COMPLETED"
    }
}

function Reset-DeliveryCompletion {

    $null = Save-DeliveryCompletionState -Records @()

    return
}