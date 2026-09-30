Set-StrictMode -Version 2.0

$ContractRuntime = Join-Path $PSScriptRoot "..\execution-result-contract\Execution-Result-Contract.ps1"
$ProvenanceRuntime = Join-Path $PSScriptRoot "..\execution-result-provenance\Execution-Result-Provenance.ps1"

if (-not (Test-Path $ContractRuntime)) {
    throw "7H-57 runtime missing: $ContractRuntime"
}

if (-not (Test-Path $ProvenanceRuntime)) {
    throw "7H-58 runtime missing: $ProvenanceRuntime"
}

. $ContractRuntime
. $ProvenanceRuntime

function Get-ExecutionResultFinalizationConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    return Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json
}

function Finalize-ExecutionResult {

    param(
        [Parameter()]
        $Result,

        [Parameter()]
        $Correlation
    )

    $Config = Get-ExecutionResultFinalizationConfig

    if ($null -eq $Result) {
        return [pscustomobject][ordered]@{
            Success       = $false
            Finalized     = $false
            Status        = "BLOCKED"
            CorrelationId = ""
            ExecutionId   = ""
            TenantId      = ""
            ClientId      = ""
            ProjectId     = ""
            WorkerId      = ""
            Output        = ""
            Redacted      = $false
            Findings      = 0
            Reason        = "RESULT_NULL"
        }
    }

    if ($null -eq $Correlation) {
        return [pscustomobject][ordered]@{
            Success       = $false
            Finalized     = $false
            Status        = "BLOCKED"
            CorrelationId = ""
            ExecutionId   = ""
            TenantId      = ""
            ClientId      = ""
            ProjectId     = ""
            WorkerId      = ""
            Output        = ""
            Redacted      = $false
            Findings      = 0
            Reason        = "CORRELATION_NULL"
        }
    }

    if ([bool]$Config.requireContractValidation) {
        $Contract = Test-ExecutionResultEnvelope $Result

        if (-not $Contract.Valid) {
            return [pscustomobject][ordered]@{
                Success       = $false
                Finalized     = $false
                Status        = "BLOCKED"
                CorrelationId = [string]$Correlation.CorrelationId
                ExecutionId   = [string]$Result.ExecutionId
                TenantId      = [string]$Result.TenantId
                ClientId      = [string]$Result.ClientId
                ProjectId     = [string]$Result.ProjectId
                WorkerId      = [string]$Result.WorkerId
                Output        = ""
                Redacted      = $false
                Findings      = 0
                Reason        = "CONTRACT_INVALID:" + $Contract.Reason
            }
        }
    }

    if ([bool]$Config.requireProvenanceValidation) {
        $Provenance = Test-ExecutionResultProvenance `
            -Result $Result `
            -Correlation $Correlation

        if (-not $Provenance.Valid) {
            return [pscustomobject][ordered]@{
                Success       = $false
                Finalized     = $false
                Status        = "BLOCKED"
                CorrelationId = [string]$Correlation.CorrelationId
                ExecutionId   = [string]$Result.ExecutionId
                TenantId      = [string]$Result.TenantId
                ClientId      = [string]$Result.ClientId
                ProjectId     = [string]$Result.ProjectId
                WorkerId      = [string]$Result.WorkerId
                Output        = ""
                Redacted      = $false
                Findings      = 0
                Reason        = "PROVENANCE_INVALID:" + $Provenance.Reason
            }
        }
    }

    if (
        (-not [bool]$Config.allowBlockedFinalization) -and
        ([string]$Result.Status -eq "BLOCKED")
    ) {
        return [pscustomobject][ordered]@{
            Success       = $false
            Finalized     = $false
            Status        = "BLOCKED"
            CorrelationId = [string]$Correlation.CorrelationId
            ExecutionId   = [string]$Result.ExecutionId
            TenantId      = [string]$Result.TenantId
            ClientId      = [string]$Result.ClientId
            ProjectId     = [string]$Result.ProjectId
            WorkerId      = [string]$Result.WorkerId
            Output        = ""
            Redacted      = $false
            Findings      = 0
            Reason        = "BLOCKED_RESULT_CANNOT_FINALIZE"
        }
    }

    return [pscustomobject][ordered]@{
        Success       = [bool]$Result.Success
        Finalized     = $true
        Status        = "FINAL"
        CorrelationId = [string]$Correlation.CorrelationId
        ExecutionId   = [string]$Result.ExecutionId
        TenantId      = [string]$Result.TenantId
        ClientId      = [string]$Result.ClientId
        ProjectId     = [string]$Result.ProjectId
        WorkerId      = [string]$Result.WorkerId
        Output        = $Result.Output
        Redacted      = [bool]$Result.Redacted
        Findings      = [int]$Result.Findings
        Reason        = "EXECUTION_RESULT_FINALIZED"
    }
}