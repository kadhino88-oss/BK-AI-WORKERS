$ErrorActionPreference = "Stop"

$GlobalGatePath = Join-Path $PSScriptRoot "..\security-gate\Global-Security-Enforcement-Gate.ps1"
$GlobalGatePath = [System.IO.Path]::GetFullPath($GlobalGatePath)

if (-not (Test-Path -LiteralPath $GlobalGatePath -PathType Leaf)) {
    throw "GLOBAL_SECURITY_GATE_MISSING"
}

. $GlobalGatePath

function Invoke-CertificationSecurityIntegration {

    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [string]$ExecutionId,

        [Parameter(Mandatory = $true)]
        [string]$UserId,

        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$SessionValid = $true,
        [bool]$RBACAuthorized = $true,
        [bool]$ScopeValid = $true,
        [bool]$AuthorizationValid = $true,
        [bool]$CapabilityAuthorized = $true,
        [bool]$AuthorityAuthorized = $true,
        [bool]$PolicyAuthorized = $true,
        [bool]$WorkerTaskAuthorized = $true,
        [bool]$CredentialAuthorized = $true,
        [bool]$ConnectorAuthorized = $true,
        [bool]$ProviderAuthorized = $true,
        [bool]$EvidenceAuthorized = $true,
        [bool]$RetentionValid = $true,
        [bool]$PurgeReuseValid = $true,
        [bool]$DirectConnectorExecution = $false,
        [bool]$DirectProviderExecution = $false,
        [bool]$SecretsPresent = $false,
        [bool]$HumanApproval = $false,
        [bool]$ProductionFlag = $false
    )

    if ($Environment -ne "CERTIFICATION") {
        throw "CERTIFICATION_ENVIRONMENT_REQUIRED"
    }

    if ($Mode -ne "CERTIFICATION") {
        throw "CERTIFICATION_MODE_REQUIRED"
    }

    $Result = Invoke-GlobalSecurityGate `
        -TenantId $TenantId `
        -ClientId $ClientId `
        -ProjectId $ProjectId `
        -ExecutionId $ExecutionId `
        -UserId $UserId `
        -Environment $Environment `
        -Mode $Mode `
        -SessionValid $SessionValid `
        -RBACAuthorized $RBACAuthorized `
        -ScopeValid $ScopeValid `
        -AuthorizationValid $AuthorizationValid `
        -CapabilityAuthorized $CapabilityAuthorized `
        -AuthorityAuthorized $AuthorityAuthorized `
        -PolicyAuthorized $PolicyAuthorized `
        -WorkerTaskAuthorized $WorkerTaskAuthorized `
        -CredentialAuthorized $CredentialAuthorized `
        -ConnectorAuthorized $ConnectorAuthorized `
        -ProviderAuthorized $ProviderAuthorized `
        -EvidenceAuthorized $EvidenceAuthorized `
        -RetentionValid $RetentionValid `
        -PurgeReuseValid $PurgeReuseValid `
        -DirectConnectorExecution $DirectConnectorExecution `
        -DirectProviderExecution $DirectProviderExecution `
        -SecretsPresent $SecretsPresent `
        -HumanApproval $HumanApproval `
        -ProductionFlag $ProductionFlag

    return $Result
}

function Assert-CertificationSecurityIntegration {

    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantId,

        [Parameter(Mandatory = $true)]
        [string]$ClientId,

        [Parameter(Mandatory = $true)]
        [string]$ProjectId,

        [Parameter(Mandatory = $true)]
        [string]$ExecutionId,

        [Parameter(Mandatory = $true)]
        [string]$UserId,

        [Parameter(Mandatory = $true)]
        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$Mode,

        [bool]$SessionValid = $true,
        [bool]$RBACAuthorized = $true,
        [bool]$ScopeValid = $true,
        [bool]$AuthorizationValid = $true,
        [bool]$CapabilityAuthorized = $true,
        [bool]$AuthorityAuthorized = $true,
        [bool]$PolicyAuthorized = $true,
        [bool]$WorkerTaskAuthorized = $true,
        [bool]$CredentialAuthorized = $true,
        [bool]$ConnectorAuthorized = $true,
        [bool]$ProviderAuthorized = $true,
        [bool]$EvidenceAuthorized = $true,
        [bool]$RetentionValid = $true,
        [bool]$PurgeReuseValid = $true,
        [bool]$DirectConnectorExecution = $false,
        [bool]$DirectProviderExecution = $false,
        [bool]$SecretsPresent = $false,
        [bool]$HumanApproval = $false,
        [bool]$ProductionFlag = $false
    )

    $Result = Invoke-CertificationSecurityIntegration @PSBoundParameters

    if ($Result.Decision -ne "ALLOW") {
        throw "CERTIFICATION_SECURITY_GATE_BLOCKED"
    }

    return $Result
}