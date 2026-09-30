Set-StrictMode -Version 2.0

$OutputSecurityRuntime = Join-Path $PSScriptRoot "..\output-security\Output-Security.ps1"

if (-not (Test-Path $OutputSecurityRuntime)) {
    throw "7H-55 runtime missing: $OutputSecurityRuntime"
}

. $OutputSecurityRuntime

function Get-ExecutionOutputSecurityConfig {

    $ConfigFile = Join-Path $PSScriptRoot "config.json"

    if (-not (Test-Path $ConfigFile)) {
        throw "Configuration file missing: $ConfigFile"
    }

    $ConfigObject = Get-Content -Raw -Path $ConfigFile | ConvertFrom-Json

    return $ConfigObject
}

function Assert-ExecutionOutputContext {
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

    if ([string]::IsNullOrWhiteSpace($ExecutionId)) {
        throw "ExecutionId context is required"
    }

    if ([string]::IsNullOrWhiteSpace($TenantId)) {
        throw "TenantId context is required"
    }

    if ([string]::IsNullOrWhiteSpace($ClientId)) {
        throw "ClientId context is required"
    }

    if ([string]::IsNullOrWhiteSpace($ProjectId)) {
        throw "ProjectId context is required"
    }

    if ([string]::IsNullOrWhiteSpace($WorkerId)) {
        throw "WorkerId context is required"
    }

    return $true
}

function Protect-ExecutionOutput {
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

        [Parameter()]
        $Output
    )

    $Config = Get-ExecutionOutputSecurityConfig

    try {
        # IMPORTANT :
        # Suppression explicite de la sortie $true de l'assertion.
        # Sinon PowerShell construit un tableau de sortie.
        $null = Assert-ExecutionOutputContext `
            -ExecutionId $ExecutionId `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -WorkerId $WorkerId
    }
    catch {
        return [pscustomobject]@{
            Success     = $false
            Status      = "BLOCKED"
            ExecutionId = $ExecutionId
            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            WorkerId    = $WorkerId
            Output      = ""
            Redacted    = $false
            Findings    = 0
            Reason      = "CONTEXT_INCOMPLETE"
        }
    }

    if (-not [bool]$Config.enabled) {
        return [pscustomobject]@{
            Success     = $false
            Status      = "BLOCKED"
            ExecutionId = $ExecutionId
            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            WorkerId    = $WorkerId
            Output      = ""
            Redacted    = $false
            Findings    = 0
            Reason      = "SECURITY_DISABLED"
        }
    }

    if (-not [bool]$Config.integrationEnabled) {
        return [pscustomobject]@{
            Success     = $false
            Status      = "BLOCKED"
            ExecutionId = $ExecutionId
            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            WorkerId    = $WorkerId
            Output      = ""
            Redacted    = $false
            Findings    = 0
            Reason      = "INTEGRATION_DISABLED"
        }
    }

    try {
        $GuardResult = Redact-SensitiveOutput $Output
    }
    catch {
        if ([bool]$Config.blockOnSecurityFailure) {
            return [pscustomobject]@{
                Success     = $false
                Status      = "BLOCKED"
                ExecutionId = $ExecutionId
                TenantId    = $TenantId
                ClientId    = $ClientId
                ProjectId   = $ProjectId
                WorkerId    = $WorkerId
                Output      = ""
                Redacted    = $false
                Findings    = 0
                Reason      = "SECURITY_GUARD_ERROR"
            }
        }

        return [pscustomobject]@{
            Success     = $true
            Status      = "UNGUARDED"
            ExecutionId = $ExecutionId
            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            WorkerId    = $WorkerId
            Output      = ""
            Redacted    = $false
            Findings    = 0
            Reason      = "SECURITY_GUARD_ERROR"
        }
    }

    if ($null -eq $GuardResult) {
        return [pscustomobject]@{
            Success     = $false
            Status      = "BLOCKED"
            ExecutionId = $ExecutionId
            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            WorkerId    = $WorkerId
            Output      = ""
            Redacted    = $false
            Findings    = 0
            Reason      = "INVALID_SECURITY_RESULT"
        }
    }

    return [pscustomobject]@{
        Success     = [bool]$GuardResult.Success
        Status      = [string]$GuardResult.Status
        ExecutionId = $ExecutionId
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
        WorkerId    = $WorkerId
        Output      = [string]$GuardResult.Output
        Redacted    = [bool]$GuardResult.Redacted
        Findings    = [int]$GuardResult.Findings
        Reason      = [string]$GuardResult.Reason
    }
}