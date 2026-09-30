Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# PSScriptRoot =
# ...\BK-AI-WORKERS\core\runtime\security-gate
# 1 parent = runtime
# 2 parents = core
# 3 parents = BK-AI-WORKERS
$script:BKRoot = Split-Path `
    -Parent `
    (Split-Path `
        -Parent `
        (Split-Path -Parent $PSScriptRoot)
    )

function New-GlobalSecurityFailure {
    param(
        [Parameter(Mandatory)]
        [string]$Reason,

        [Parameter(Mandatory)]
        [string]$Stage,

        [Parameter(Mandatory)]
        [hashtable]$Context
    )

    [pscustomobject]@{
        Schema            = "BK-AI-WORKERS-GLOBAL-SECURITY-GATE"
        Decision          = "BLOCK"
        Authorized        = $false
        Reason            = $Reason
        FailedStage       = $Stage
        TenantId          = $Context.TenantId
        ClientId          = $Context.ClientId
        ProjectId         = $Context.ProjectId
        ExecutionId       = $Context.ExecutionId
        UserId            = $Context.UserId
        Environment       = $Context.Environment
        Mode              = $Context.Mode
        SecurityIntegrity = $false
        SecretsPresent    = $false
        TimestampUtc      = [DateTime]::UtcNow.ToString("o")
    }
}

function Get-GlobalSecurityModuleManifest {

    @(
        @{
            Name = "RBAC"
            Path = "core/security/rbac/RBAC.ps1"
        },
        @{
            Name = "SessionTokenSecurity"
            Path = "core/security/session-token-security/runtime.ps1"
        },
        @{
            Name = "SealRetention"
            Path = "core/security/credential-recovery-seal-retention/Seal-Retention-Guard.ps1"
        },
        @{
            Name = "EvidenceExpiration"
            Path = "core/security/credential-recovery/evidence-expiration/Evidence-Expiration-Guard.ps1"
        },
        @{
            Name = "EvidencePurgeReuse"
            Path = "core/security/credential-recovery/evidence-purge-reuse/Evidence-Purge-Reuse-Guard.ps1"
        },
        @{
            Name = "ExecutionPolicy"
            Path = "core/runtime/execution-policy/EXECUTION-POLICY-ENGINE.ps1"
        },
        @{
            Name = "AuthorityGate"
            Path = "core/runtime/authority-gate/Authority-Gate.ps1"
        },
        @{
            Name = "EnvironmentGuard"
            Path = "core/runtime/environment-guard/Environment-Guard.ps1"
        },
        @{
            Name = "IntegrationEnforcer"
            Path = "core/runtime/integration-enforcement/INTEGRATION-RUNTIME-ENFORCER.ps1"
        },
        @{
            Name = "ConnectorGateway"
            Path = "core/runtime/execution-gateway/EXTERNAL-CONNECTOR-EXECUTION-GATEWAY.ps1"
        }
    )
}

function Test-GlobalSecurityIntegrity {

    $Manifest = Get-GlobalSecurityModuleManifest

    foreach ($Module in $Manifest) {

        $FullPath = Join-Path $script:BKRoot $Module.Path

        if (-not (Test-Path -LiteralPath $FullPath -PathType Leaf)) {
            return [pscustomobject]@{
                Valid  = $false
                Reason = "SECURITY_MODULE_MISSING"
                Module = $Module.Name
                Path   = $FullPath
                Hash   = $null
            }
        }

        try {
            $Hash = (Get-FileHash `
                -LiteralPath $FullPath `
                -Algorithm SHA256).Hash

            if ([string]::IsNullOrWhiteSpace($Hash)) {
                return [pscustomobject]@{
                    Valid  = $false
                    Reason = "SECURITY_MODULE_HASH_EMPTY"
                    Module = $Module.Name
                    Path   = $FullPath
                    Hash   = $null
                }
            }
        }
        catch {
            return [pscustomobject]@{
                Valid  = $false
                Reason = "SECURITY_MODULE_HASH_FAILED"
                Module = $Module.Name
                Path   = $FullPath
                Hash   = $null
            }
        }
    }

    return [pscustomobject]@{
        Valid  = $true
        Reason = "SECURITY_MODULES_INTEGRITY_VALID"
        Module = $null
        Path   = $script:BKRoot
        Hash   = $null
    }
}

function Invoke-GlobalSecurityGate {

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
        [string]$Environment,

        [Parameter(Mandatory)]
        [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
        [string]$Mode,

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
        [bool]$ProductionFlag = $false
    )

    $Context = @{
        TenantId    = $TenantId
        ClientId    = $ClientId
        ProjectId   = $ProjectId
        ExecutionId = $ExecutionId
        UserId      = $UserId
        Environment = $Environment.ToUpper()
        Mode        = $Mode.ToUpper()
    }

    # ========================================================
    # 1. CONTEXTE D'IDENTITE
    # ========================================================

    foreach ($Key in @(
        "TenantId",
        "ClientId",
        "ProjectId",
        "ExecutionId",
        "UserId"
    )) {
        if ([string]::IsNullOrWhiteSpace([string]$Context[$Key])) {
            return New-GlobalSecurityFailure `
                -Reason "IDENTITY_CONTEXT_REQUIRED" `
                -Stage "IDENTITY" `
                -Context $Context
        }
    }

    # ========================================================
    # 2. ENVIRONNEMENT
    # ========================================================

    if ($Context.Environment -notin @(
        "SIMULATION",
        "SANDBOX",
        "CERTIFICATION",
        "PILOT",
        "LIVE"
    )) {
        return New-GlobalSecurityFailure `
            -Reason "INVALID_ENVIRONMENT" `
            -Stage "ENVIRONMENT" `
            -Context $Context
    }

    # ========================================================
    # 3. ANTI-BYPASS
    # ========================================================

    if ($DirectConnectorExecution) {
        return New-GlobalSecurityFailure `
            -Reason "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN" `
            -Stage "CONNECTOR" `
            -Context $Context
    }

    if ($DirectProviderExecution) {
        return New-GlobalSecurityFailure `
            -Reason "DIRECT_PROVIDER_EXECUTION_FORBIDDEN" `
            -Stage "PROVIDER" `
            -Context $Context
    }

    if ($SecretsPresent) {
        return New-GlobalSecurityFailure `
            -Reason "SECRETS_CANNOT_ENTER_SECURITY_GATE" `
            -Stage "SECRET_BOUNDARY" `
            -Context $Context
    }

    # ========================================================
    # 4. INTÉGRITÉ DES MODULES DE SÉCURITÉ
    # ========================================================

    $Integrity = Test-GlobalSecurityIntegrity

    if (-not $Integrity.Valid) {
        return New-GlobalSecurityFailure `
            -Reason $Integrity.Reason `
            -Stage "SECURITY_INTEGRITY" `
            -Context $Context
    }

    # ========================================================
    # 5. CHAÎNE OBLIGATOIRE
    # ========================================================

    $Stages = @(
        @{ Name = "SESSION";       Valid = $SessionValid },
        @{ Name = "RBAC";          Valid = $RBACAuthorized },
        @{ Name = "SCOPE";         Valid = $ScopeValid },
        @{ Name = "AUTHORIZATION"; Valid = $AuthorizationValid },
        @{ Name = "CAPABILITY";    Valid = $CapabilityAuthorized },
        @{ Name = "AUTHORITY";     Valid = $AuthorityAuthorized },
        @{ Name = "POLICY";        Valid = $PolicyAuthorized },
        @{ Name = "WORKER_TASK";   Valid = $WorkerTaskAuthorized },
        @{ Name = "CREDENTIAL";    Valid = $CredentialAuthorized },
        @{ Name = "CONNECTOR";     Valid = $ConnectorAuthorized },
        @{ Name = "PROVIDER";      Valid = $ProviderAuthorized },
        @{ Name = "EVIDENCE";      Valid = $EvidenceAuthorized },
        @{ Name = "RETENTION";     Valid = $RetentionValid },
        @{ Name = "PURGE_REUSE";   Valid = $PurgeReuseValid }
    )

    foreach ($Stage in $Stages) {

        if ($Stage.Valid -ne $true) {
            return New-GlobalSecurityFailure `
                -Reason "SECURITY_STAGE_NOT_AUTHORIZED:$($Stage.Name)" `
                -Stage $Stage.Name `
                -Context $Context
        }
    }

    # ========================================================
    # 6. LIVE : EXIGENCES SUPPLÉMENTAIRES
    # ========================================================

    if ($Context.Mode -eq "LIVE") {

        if ($Context.Environment -ne "LIVE") {
            return New-GlobalSecurityFailure `
                -Reason "LIVE_REQUIRES_LIVE_ENVIRONMENT" `
                -Stage "LIVE_ENVIRONMENT" `
                -Context $Context
        }

        if ($HumanApproval -ne $true) {
            return New-GlobalSecurityFailure `
                -Reason "HUMAN_APPROVAL_REQUIRED" `
                -Stage "LIVE_AUTHORIZATION" `
                -Context $Context
        }

        if ($ProductionFlag -ne $true) {
            return New-GlobalSecurityFailure `
                -Reason "PRODUCTION_FLAG_REQUIRED" `
                -Stage "LIVE_AUTHORIZATION" `
                -Context $Context
        }
    }

    # ========================================================
    # 7. ALLOW GLOBAL
    # ========================================================

    [pscustomobject]@{
        Schema              = "BK-AI-WORKERS-GLOBAL-SECURITY-GATE"
        Decision            = "ALLOW"
        Authorized          = $true
        Reason              = "GLOBAL_SECURITY_CHAIN_VALID"
        FailedStage         = $null

        TenantId            = $TenantId
        ClientId            = $ClientId
        ProjectId           = $ProjectId
        ExecutionId         = $ExecutionId
        UserId              = $UserId

        Environment         = $Context.Environment
        Mode                = $Context.Mode

        SecurityIntegrity   = $true

        DirectConnector     = $false
        DirectProvider      = $false
        SecretsPresent      = $false

        TimestampUtc        = [DateTime]::UtcNow.ToString("o")
    }
}

function Assert-GlobalSecurityGate {

    param(
        [Parameter(Mandatory)]
        [hashtable]$Parameters
    )

    $Result = Invoke-GlobalSecurityGate @Parameters

    if ($Result.Authorized -ne $true) {
        throw "GLOBAL_SECURITY_GATE_BLOCKED:$($Result.Reason)"
    }

    return $Result
}