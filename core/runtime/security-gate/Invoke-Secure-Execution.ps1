Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path `
    -Parent `
    (Split-Path `
        -Parent `
        (Split-Path -Parent $PSScriptRoot)
    )

$GlobalGate = Join-Path `
    $Root `
    "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"

if (-not (Test-Path -LiteralPath $GlobalGate -PathType Leaf)) {
    throw "GLOBAL_SECURITY_GATE_MISSING"
}

. $GlobalGate

function Invoke-SecureExecution {

    param(
        [Parameter(Mandatory)]
        [string]$TenantId,

        [Parameter(Mandatory)]
        [string]$ClientId,

        [Parameter(Mandatory)]
        [string]$ProjectId,

        [Parameter(Mandatory)]
        [string]$ExecutionId,

        [Parameter(Mandatory)]
        [string]$UserId,

        [Parameter(Mandatory)]
        [ValidateSet(
            "SIMULATION",
            "SANDBOX",
            "CERTIFICATION",
            "PILOT",
            "LIVE"
        )]
        [string]$Mode,

        [Parameter(Mandatory)]
        [string]$Environment,

        [string]$Target = "ORCHESTRATOR",

        [bool]$SessionValid = $false,
        [bool]$RBACAuthorized = $false,
        [bool]$ScopeValid = $false,
        [bool]$AuthorizationValid = $false,
        [bool]$CapabilityAuthorized = $false,
        [bool]$AuthorityAuthorized = $false,
        [bool]$PolicyAuthorized = $false,
        [bool]$WorkerTaskAuthorized = $false,
        [bool]$CredentialAuthorized = $false,
        [bool]$ConnectorAuthorized = $false,
        [bool]$ProviderAuthorized = $false,
        [bool]$EvidenceAuthorized = $false,
        [bool]$RetentionValid = $false,
        [bool]$PurgeReuseValid = $false,

        [bool]$DirectConnectorExecution = $false,
        [bool]$DirectProviderExecution = $false,
        [bool]$SecretsPresent = $false,

        [bool]$HumanApproval = $false,
        [bool]$ProductionFlag = $false,

        [scriptblock]$ExecutionHandler
    )

    # ========================================================
    # ABSOLUTE SECURITY PRE-CHECK
    # ========================================================

    if ([string]::IsNullOrWhiteSpace($Target)) {
        throw "SECURE_EXECUTION_TARGET_REQUIRED"
    }

    # ========================================================
    # GLOBAL SECURITY GATE
    # ========================================================

    $GateParameters = @{
        TenantId                    = $TenantId
        ClientId                    = $ClientId
        ProjectId                   = $ProjectId
        ExecutionId                 = $ExecutionId
        UserId                      = $UserId
        Environment                 = $Environment
        Mode                        = $Mode

        SessionValid                = $SessionValid
        RBACAuthorized              = $RBACAuthorized
        ScopeValid                  = $ScopeValid
        AuthorizationValid          = $AuthorizationValid
        CapabilityAuthorized        = $CapabilityAuthorized
        AuthorityAuthorized         = $AuthorityAuthorized
        PolicyAuthorized             = $PolicyAuthorized
        WorkerTaskAuthorized         = $WorkerTaskAuthorized
        CredentialAuthorized         = $CredentialAuthorized
        ConnectorAuthorized          = $ConnectorAuthorized
        ProviderAuthorized           = $ProviderAuthorized
        EvidenceAuthorized           = $EvidenceAuthorized
        RetentionValid               = $RetentionValid
        PurgeReuseValid              = $PurgeReuseValid

        DirectConnectorExecution     = $DirectConnectorExecution
        DirectProviderExecution      = $DirectProviderExecution
        SecretsPresent               = $SecretsPresent

        HumanApproval                = $HumanApproval
        ProductionFlag               = $ProductionFlag
    }

    $SecurityDecision = Invoke-GlobalSecurityGate @GateParameters

    if ($SecurityDecision.Authorized -ne $true) {

        return [pscustomobject]@{
            Schema      = "BK-AI-WORKERS-SECURE-EXECUTION-ENTRY"
            Decision    = "BLOCK"
            Authorized  = $false
            Reason      = $SecurityDecision.Reason
            FailedStage = $SecurityDecision.FailedStage
            Target      = $Target

            TenantId    = $TenantId
            ClientId    = $ClientId
            ProjectId   = $ProjectId
            ExecutionId = $ExecutionId
            UserId      = $UserId

            Environment = $Environment
            Mode        = $Mode

            Executed    = $false
            Bypass      = $false

            TimestampUtc = [DateTime]::UtcNow.ToString("o")
        }
    }

    # ========================================================
    # GLOBAL GATE PASSED
    # ========================================================

    if ($null -eq $ExecutionHandler) {

        return [pscustomobject]@{
            Schema       = "BK-AI-WORKERS-SECURE-EXECUTION-ENTRY"
            Decision     = "AUTHORIZED"
            Authorized   = $true
            Reason       = "SECURITY_GATE_PASSED_EXECUTION_HANDLER_REQUIRED"
            FailedStage  = $null
            Target       = $Target

            TenantId     = $TenantId
            ClientId     = $ClientId
            ProjectId    = $ProjectId
            ExecutionId  = $ExecutionId
            UserId       = $UserId

            Environment  = $Environment
            Mode         = $Mode

            Executed     = $false
            Bypass       = $false

            TimestampUtc = [DateTime]::UtcNow.ToString("o")
        }
    }

    # ========================================================
    # EXECUTION AFTER SECURITY DECISION ONLY
    # ========================================================

    try {

        $ExecutionResult = & $ExecutionHandler

        return [pscustomobject]@{
            Schema       = "BK-AI-WORKERS-SECURE-EXECUTION-ENTRY"
            Decision     = "EXECUTED"
            Authorized   = $true
            Reason       = "SECURITY_GATE_PASSED_EXECUTION_COMPLETED"
            FailedStage  = $null
            Target       = $Target

            TenantId     = $TenantId
            ClientId     = $ClientId
            ProjectId    = $ProjectId
            ExecutionId  = $ExecutionId
            UserId       = $UserId

            Environment  = $Environment
            Mode         = $Mode

            Executed     = $true
            Bypass       = $false

            Result       = $ExecutionResult

            TimestampUtc = [DateTime]::UtcNow.ToString("o")
        }

    }
    catch {

        return [pscustomobject]@{
            Schema       = "BK-AI-WORKERS-SECURE-EXECUTION-ENTRY"
            Decision     = "EXECUTION_FAILED"
            Authorized   = $true
            Reason       = "AUTHORIZED_EXECUTION_HANDLER_FAILED"
            FailedStage  = "EXECUTION"

            Target       = $Target

            TenantId     = $TenantId
            ClientId     = $ClientId
            ProjectId    = $ProjectId
            ExecutionId  = $ExecutionId
            UserId       = $UserId

            Environment  = $Environment
            Mode         = $Mode

            Executed     = $false
            Bypass       = $false

            Error        = $_.Exception.Message

            TimestampUtc = [DateTime]::UtcNow.ToString("o")
        }
    }
}

function Assert-SecureExecutionAuthorized {

    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    $Result = Invoke-SecureExecution @Parameters

    if ($Result.Authorized -ne $true) {
        throw "SECURE_EXECUTION_BLOCKED:$($Result.Reason)"
    }

    return $Result
}