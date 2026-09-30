Set-StrictMode -Version 2.0

function Get-ExecutionResultDeliveryConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-AllowedDeliveryChannels {

    $Config = Get-ExecutionResultDeliveryConfig

    $Channels = @($Config.allowedChannels)

    return $Channels
}

function New-ExecutionResultDeliveryTarget {

    param(
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
        [string]$WorkerId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$TargetId,

        [Parameter(Mandatory=$true)]
        [AllowEmptyString()]
        [string]$Channel
    )

    return [pscustomobject][ordered]@{
        DeliveryId  = [guid]::NewGuid().ToString("N")
        ExecutionId = $ExecutionId
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
        WorkerId    = $WorkerId
        TargetId    = $TargetId
        Channel     = $Channel
    }
}

function Test-ExecutionResultDelivery {

    param(
        [Parameter()]
        $Result,

        [Parameter()]
        $Target
    )

    $Config = Get-ExecutionResultDeliveryConfig

    if ($null -eq $Result) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RESULT_NULL"
        }
    }

    if ($null -eq $Target) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "DELIVERY_TARGET_NULL"
        }
    }

    if ([bool]$Config.requireFinalizedResult) {

        $FinalizedProperty = @($Result.PSObject.Properties) |
            Where-Object { $_.Name -eq "Finalized" } |
            Select-Object -First 1

        if ($null -eq $FinalizedProperty) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "FINALIZED_FIELD_MISSING"
            }
        }

        if ($Result.Finalized -ne $true) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "RESULT_NOT_FINALIZED"
            }
        }
    }

    if ([string]$Result.Status -ne "FINAL") {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RESULT_NOT_FINAL"
        }
    }

    if ([bool]$Config.requireExecutionId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.ExecutionId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "EXECUTION_ID_MISSING"
            }
        }
    }

    if ([string]$Result.ExecutionId -ne [string]$Target.ExecutionId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "EXECUTION_ID_MISMATCH"
        }
    }

    if ([bool]$Config.requireTenantId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.TenantId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "TENANT_ID_MISSING"
            }
        }
    }

    if ([string]$Result.TenantId -ne [string]$Target.TenantId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "TENANT_MISMATCH"
        }
    }

    if ([bool]$Config.requireClientId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.ClientId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "CLIENT_ID_MISSING"
            }
        }
    }

    if ([string]$Result.ClientId -ne [string]$Target.ClientId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "CLIENT_MISMATCH"
        }
    }

    if ([bool]$Config.requireProjectId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.ProjectId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "PROJECT_ID_MISSING"
            }
        }
    }

    if ([string]$Result.ProjectId -ne [string]$Target.ProjectId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "PROJECT_MISMATCH"
        }
    }

    if ([bool]$Config.requireWorkerId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.WorkerId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "WORKER_ID_MISSING"
            }
        }
    }

    if ([string]$Result.WorkerId -ne [string]$Target.WorkerId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "WORKER_MISMATCH"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$Target.TargetId)) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "TARGET_ID_MISSING"
        }
    }

    $ChannelValid = $false

    foreach ($Channel in @(Get-AllowedDeliveryChannels)) {
        if ([string]$Target.Channel -eq [string]$Channel) {
            $ChannelValid = $true
            break
        }
    }

    if (-not $ChannelValid) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "CHANNEL_INVALID"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "VALID"
        Reason = "DELIVERY_AUTHORIZED"
    }
}

function Protect-ExecutionResultDelivery {

    param(
        [Parameter()]
        $Result,

        [Parameter()]
        $Target
    )

    $Validation = Test-ExecutionResultDelivery `
        -Result $Result `
        -Target $Target

    if (-not $Validation.Valid) {

        $CorrelationId = ""

        if ($null -ne $Result) {
            $CorrelationProperty = @($Result.PSObject.Properties) |
                Where-Object { $_.Name -eq "CorrelationId" } |
                Select-Object -First 1

            if ($null -ne $CorrelationProperty) {
                $CorrelationId = [string]$Result.CorrelationId
            }
        }

        return [pscustomobject][ordered]@{
            Success       = $false
            Delivered     = $false
            Status        = "BLOCKED"
            DeliveryId    = ""
            CorrelationId = $CorrelationId
            ExecutionId   = ""
            TenantId      = ""
            ClientId      = ""
            ProjectId     = ""
            WorkerId      = ""
            TargetId      = ""
            Channel       = ""
            Output        = ""
            Reason        = $Validation.Reason
        }
    }

    return [pscustomobject][ordered]@{
        Success       = $true
        Delivered     = $false
        Status        = "AUTHORIZED"
        DeliveryId    = [string]$Target.DeliveryId
        CorrelationId = if ($null -ne $Result.CorrelationId) { [string]$Result.CorrelationId } else { "" }
        ExecutionId   = [string]$Result.ExecutionId
        TenantId      = [string]$Result.TenantId
        ClientId      = [string]$Result.ClientId
        ProjectId     = [string]$Result.ProjectId
        WorkerId      = [string]$Result.WorkerId
        TargetId      = [string]$Target.TargetId
        Channel       = [string]$Target.Channel
        Output        = $Result.Output
        Reason        = "DELIVERY_AUTHORIZED_SIMULATION"
    }
}