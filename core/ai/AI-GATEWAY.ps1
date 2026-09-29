[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$ProjectId,
    [string]$ExecutionId,
    [string]$UserId,
    [string]$Environment = "SIMULATION",
    [string]$Mode = "SIMULATION",
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

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$GatePath = Join-Path $Root "core\runtime\security-gate\Global-Security-Enforcement-Gate.ps1"
$Original = "C:\Users\FEUCOM\BK-AI-WORKERS\core\ai\backups\8A-49L-20260911-213650\AI-GATEWAY.original.ps1"

. $GatePath

$GateParameters = @{
    TenantId                 = $TenantId
    ClientId                 = $ClientId
    ProjectId                = $ProjectId
    ExecutionId              = $ExecutionId
    UserId                   = $UserId
    Environment              = $Environment
    Mode                     = $Mode
    SessionValid             = $SessionValid
    RBACAuthorized           = $RBACAuthorized
    ScopeValid               = $ScopeValid
    AuthorizationValid       = $AuthorizationValid
    CapabilityAuthorized     = $CapabilityAuthorized
    AuthorityAuthorized      = $AuthorityAuthorized
    PolicyAuthorized         = $PolicyAuthorized
    WorkerTaskAuthorized     = $WorkerTaskAuthorized
    CredentialAuthorized     = $CredentialAuthorized
    ConnectorAuthorized      = $ConnectorAuthorized
    ProviderAuthorized       = $ProviderAuthorized
    EvidenceAuthorized       = $EvidenceAuthorized
    RetentionValid           = $RetentionValid
    PurgeReuseValid          = $PurgeReuseValid
    DirectConnectorExecution = $DirectConnectorExecution
    DirectProviderExecution  = $DirectProviderExecution
    SecretsPresent           = $SecretsPresent
    HumanApproval            = $HumanApproval
    ProductionFlag           = $ProductionFlag
}

if ($DirectProviderExecution) {
    throw "DIRECT_PROVIDER_EXECUTION_FORBIDDEN"
}

if ($DirectConnectorExecution) {
    throw "DIRECT_CONNECTOR_EXECUTION_FORBIDDEN"
}

if ($SecretsPresent) {
    throw "SECRETS_FORBIDDEN"
}

if (-not $SessionValid) {
    throw "SESSION_PROOF_REQUIRED"
}

$GateResult = Invoke-GlobalSecurityGate @GateParameters

if ($null -eq $GateResult) {
    throw "GLOBAL_SECURITY_GATE_NO_RESULT"
}

if ($GateResult.Authorized -ne $true -or
    $GateResult.Decision -ne "ALLOW") {
    throw "GLOBAL_SECURITY_GATE_BLOCKED:$($GateResult.Reason)"
}

& $Original @PSBoundParameters