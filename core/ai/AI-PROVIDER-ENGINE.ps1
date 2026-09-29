[CmdletBinding()]
param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$ProjectId,
    [string]$ExecutionId,
    [string]$UserId,
    [string]$Environment = "SIMULATION",
    [string]$Mode = "SIMULATION",

    # Parametres metier reellement necessaires au moteur
    # sous-jacent (AI-PROVIDER-ENGINE.original.ps1). Sans
    # eux, le splat vers $Original echouait (parametres
    # obligatoires manquants) : bug corrige le 2026-09-14,
    # cf. Invoke-Worker-AI.ps1 qui les fournit desormais.
    [Parameter(Mandatory=$true)][string]$WorkerId,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Objective,
    [ValidateSet("NONE","OPENAI","ANTHROPIC")]
    [string]$Provider = "NONE",
    [string]$Model = "NONE",
    [string]$ContextPath = "",
    [string]$MemoryPath = "",

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

$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
$GatePath = Join-Path $Root "core/runtime/security-gate/Global-Security-Enforcement-Gate.ps1"
# Anciennement pointe vers core\ai\backups\8A-49L-...\AI-PROVIDER-ENGINE.original.ps1 :
# ce script utilise $PSScriptRoot pour retrouver AI-PROVIDERS.json a cote de lui, ce qui
# echouait depuis un dossier backups/ (CONFIG:ERROR). Copie a un emplacement permanent le
# 2026-09-14 ; le fichier backups/ original reste intact, inchange.
$Original = Join-Path $Root "core/ai/AI-PROVIDER-ENGINE-LOCAL.ps1"

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

# On ne re-splatte PAS @PSBoundParameters : $Original n'accepte
# pas les flags du Gate (CapabilityAuthorized, etc.), seulement
# les parametres metier ci-dessous. Le Gate a deja ete verifie
# ci-dessus ; c'est cette verification qui autorise cet appel,
# pas un contournement.
& $Original `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -TaskId $TaskId `
    -Objective $Objective `
    -Provider $Provider `
    -Model $Model `
    -ContextPath $ContextPath `
    -MemoryPath $MemoryPath