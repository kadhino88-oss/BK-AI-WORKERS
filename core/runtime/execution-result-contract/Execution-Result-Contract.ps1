Set-StrictMode -Version 2.0

function Get-ExecutionResultContractConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Get-ExecutionResultRequiredFields {

    return @(
        "Success"
        "Status"
        "ExecutionId"
        "TenantId"
        "ClientId"
        "ProjectId"
        "WorkerId"
        "Output"
        "Redacted"
        "Findings"
        "Reason"
    )
}

function Get-ExecutionResultAllowedStatuses {

    return @(
        "CLEAN"
        "REDACTED"
        "BLOCKED"
        "UNSAFE"
        "SAFE"
        "ERROR"
        "UNGUARDED"
    )
}

function New-ExecutionResultEnvelope {

    param(
        [Parameter(Mandatory=$true)]
        [bool]$Success,

        [Parameter(Mandatory=$true)]
        [string]$Status,

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

        [Parameter()]
        $Output,

        [Parameter(Mandatory=$true)]
        [bool]$Redacted,

        [Parameter(Mandatory=$true)]
        [int]$Findings,

        [Parameter(Mandatory=$true)]
        [string]$Reason
    )

    return [pscustomobject][ordered]@{
        Success     = $Success
        Status      = $Status
        ExecutionId = $ExecutionId
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
        WorkerId    = $WorkerId
        Output      = $Output
        Redacted    = $Redacted
        Findings    = $Findings
        Reason      = $Reason
    }
}

function Test-ExecutionResultEnvelope {

    param(
        [Parameter()]
        $Result
    )

    $Config = Get-ExecutionResultContractConfig

    if ($null -eq $Result) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RESULT_NULL"
        }
    }

    $Properties = @($Result.PSObject.Properties)

    foreach ($Field in @(Get-ExecutionResultRequiredFields)) {

        $Found = $false

        foreach ($Property in $Properties) {
            if ([string]$Property.Name -eq $Field) {
                $Found = $true
                break
            }
        }

        if (-not $Found) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "FIELD_MISSING:$Field"
            }
        }
    }

    if ([bool]$Config.rejectUnknownStatus) {

        $AllowedStatus = $false

        foreach ($Value in @(Get-ExecutionResultAllowedStatuses)) {
            if ([string]$Result.Status -eq $Value) {
                $AllowedStatus = $true
                break
            }
        }

        if (-not $AllowedStatus) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "STATUS_INVALID"
            }
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

    if ([bool]$Config.requireTenantId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.TenantId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "TENANT_ID_MISSING"
            }
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

    if ([bool]$Config.requireProjectId) {
        if ([string]::IsNullOrWhiteSpace([string]$Result.ProjectId)) {
            return [pscustomobject]@{
                Valid  = $false
                Status = "BLOCKED"
                Reason = "PROJECT_ID_MISSING"
            }
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

    if ([int]$Result.Findings -lt 0) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "FINDINGS_INVALID"
        }
    }

    if ($Result.Redacted -isnot [bool]) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "REDACTED_INVALID"
        }
    }

    if ($Result.Success -isnot [bool]) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "SUCCESS_INVALID"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "VALID"
        Reason = "RESULT_CONTRACT_VALID"
    }
}

function Protect-ExecutionResultEnvelope {

    param(
        [Parameter()]
        $Result
    )

    $Validation = Test-ExecutionResultEnvelope $Result

    if (-not $Validation.Valid) {

        return [pscustomobject][ordered]@{
            Success     = $false
            Status      = "BLOCKED"
            ExecutionId = ""
            TenantId    = ""
            ClientId    = ""
            ProjectId   = ""
            WorkerId    = ""
            Output      = ""
            Redacted    = $false
            Findings    = 0
            Reason      = $Validation.Reason
        }
    }

    return [pscustomobject][ordered]@{
        Success     = [bool]$Result.Success
        Status      = [string]$Result.Status
        ExecutionId = [string]$Result.ExecutionId
        TenantId    = [string]$Result.TenantId
        ClientId    = [string]$Result.ClientId
        ProjectId   = [string]$Result.ProjectId
        WorkerId    = [string]$Result.WorkerId
        Output      = $Result.Output
        Redacted    = [bool]$Result.Redacted
        Findings    = [int]$Result.Findings
        Reason      = [string]$Result.Reason
    }
}