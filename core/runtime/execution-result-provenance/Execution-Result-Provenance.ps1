Set-StrictMode -Version 2.0

function Get-ExecutionResultProvenanceConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function New-ExecutionResultCorrelation {

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
        [string]$WorkerId
    )

    return [pscustomobject][ordered]@{
        CorrelationId = [guid]::NewGuid().ToString("N")
        ExecutionId   = $ExecutionId
        TenantId      = $TenantId
        ClientId      = $ClientId
        ProjectId     = $ProjectId
        WorkerId      = $WorkerId
    }
}

function Test-ExecutionResultProvenance {

    param(
        [Parameter()]
        $Result,

        [Parameter()]
        $Correlation
    )

    $Config = Get-ExecutionResultProvenanceConfig

    if ($null -eq $Result) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "RESULT_NULL"
        }
    }

    if ($null -eq $Correlation) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "CORRELATION_NULL"
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

    if ([string]$Result.ExecutionId -ne [string]$Correlation.ExecutionId) {
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

    if ([string]$Result.TenantId -ne [string]$Correlation.TenantId) {
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

    if ([string]$Result.ClientId -ne [string]$Correlation.ClientId) {
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

    if ([string]$Result.ProjectId -ne [string]$Correlation.ProjectId) {
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

    if ([string]$Result.WorkerId -ne [string]$Correlation.WorkerId) {
        return [pscustomobject]@{
            Valid  = $false
            Status = "BLOCKED"
            Reason = "WORKER_MISMATCH"
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Status = "VALID"
        Reason = "PROVENANCE_VALID"
    }
}

function Protect-ExecutionResultProvenance {

    param(
        [Parameter()]
        $Result,

        [Parameter()]
        $Correlation
    )

    $Validation = Test-ExecutionResultProvenance `
        -Result $Result `
        -Correlation $Correlation

    if (-not $Validation.Valid) {

        return [pscustomobject][ordered]@{
            Success       = $false
            Status        = "BLOCKED"
            CorrelationId = if ($null -ne $Correlation) { [string]$Correlation.CorrelationId } else { "" }
            ExecutionId   = ""
            TenantId      = ""
            ClientId      = ""
            ProjectId     = ""
            WorkerId      = ""
            Output        = ""
            Redacted      = $false
            Findings      = 0
            Reason        = $Validation.Reason
        }
    }

    return [pscustomobject][ordered]@{
        Success       = [bool]$Result.Success
        Status        = [string]$Result.Status
        CorrelationId = [string]$Correlation.CorrelationId
        ExecutionId   = [string]$Result.ExecutionId
        TenantId      = [string]$Result.TenantId
        ClientId      = [string]$Result.ClientId
        ProjectId     = [string]$Result.ProjectId
        WorkerId      = [string]$Result.WorkerId
        Output        = $Result.Output
        Redacted      = [bool]$Result.Redacted
        Findings      = [int]$Result.Findings
        Reason        = [string]$Result.Reason
    }
}