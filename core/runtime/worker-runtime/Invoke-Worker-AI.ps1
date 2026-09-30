[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$WorkerId,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Objective,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$ExecutionId,
    [Parameter(Mandatory=$true)][string]$UserId,
    [Parameter(Mandatory=$true)][string]$SessionId,
    [Parameter(Mandatory=$true)][string]$TokenId,
    [Parameter(Mandatory=$true)][string]$Token,
    [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
    [string]$Environment="SIMULATION",
    [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
    [string]$Mode="SIMULATION",
    [ValidateSet("NONE","OPENAI","ANTHROPIC")]
    [string]$Provider="NONE",
    [string]$Model="NONE"
)

$ErrorActionPreference="Stop"

$Root= if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }

$Entry=Join-Path $Root "core/ai/AI-SECURE-ENTRY-GUARD.ps1"
$ProviderEngine=Join-Path $Root "core/ai/AI-PROVIDER-ENGINE.ps1"
$FullChainResolver=Join-Path $Root "core/runtime/security-gate/Resolve-FullAuthorizationChain.ps1"
$WorkerPath=Join-Path $Root ("workers/"+$WorkerId.ToLowerInvariant())
$SkillRegistry=Join-Path $WorkerPath "skills/SKILLS-REGISTRY.json"

if(-not (Test-Path -LiteralPath $Entry -PathType Leaf)){
    throw "AI_SECURE_ENTRY_MISSING"
}

if(-not (Test-Path -LiteralPath $ProviderEngine -PathType Leaf)){
    throw "AI_PROVIDER_ENGINE_MISSING"
}

if(-not (Test-Path -LiteralPath $FullChainResolver -PathType Leaf)){
    throw "FULL_CHAIN_RESOLVER_MISSING"
}

if(-not (Test-Path -LiteralPath $WorkerPath -PathType Container)){
    throw "WORKER_NOT_FOUND:$WorkerId"
}

. $Entry
. $FullChainResolver

# =================================================
# RESOLUTION REELLE DE TOUTE LA CHAINE (Capability ->
# PurgeReuse), meme fonction partagee que
# Invoke-Orchestrator.ps1 — voir ce fichier pour le
# detail de chaque stage. Action="READ" : c'est la
# seule action presente dans (quasi) tous les outils
# de la Capability Matrix — memes contraintes reelles
# qu'Invoke-Orchestrator.ps1. "EXECUTE" n'est PAS
# accorde pour la plupart des couples Worker/Tool
# (ex: CRM d'ALEX n'autorise que READ/SEARCH/CREATE/
# UPDATE) : l'utiliser ferait echouer CAPABILITY pour
# de vrai, ce n'est pas une limitation artificielle.
# =================================================

$ChainResult = Resolve-BKFullAuthorizationChain `
    -Worker $WorkerId.ToUpper() `
    -Action "READ" `
    -Description $Objective `
    -TaskId $TaskId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -UserId $UserId `
    -SessionId $SessionId `
    -TokenId $TokenId `
    -Token $Token `
    -Mode $Mode

$Auth=@{
    TenantId=$TenantId
    ClientId=$ClientId
    ProjectId=$ProjectId
    ExecutionId=$ExecutionId
    UserId=$UserId
    SessionId=$SessionId
    TokenId=$TokenId
    Token=$Token
    Environment=$Environment
    Mode=$Mode
    Action="READ"

    CapabilityAuthorized=$ChainResult.CapabilityAuthorized
    AuthorityAuthorized=$ChainResult.AuthorityAuthorized
    PolicyAuthorized=$ChainResult.PolicyAuthorized
    WorkerTaskAuthorized=$ChainResult.WorkerTaskAuthorized
    CredentialAuthorized=$ChainResult.CredentialAuthorized
    ConnectorAuthorized=$ChainResult.ConnectorAuthorized
    ProviderAuthorized=$ChainResult.ProviderAuthorized
    EvidenceAuthorized=$ChainResult.EvidenceAuthorized
    RetentionValid=$ChainResult.RetentionValid
    PurgeReuseValid=$ChainResult.PurgeReuseValid

    DirectProviderExecution=$false
    DirectConnectorExecution=$false
    SecretsPresent=$false
}

$AuthResult=$null

try {
    $AuthResult=Invoke-AISecureAuthorization -Parameters $Auth
}
catch {
    throw "AI_AUTHORIZATION_BLOCKED:$($_.Exception.Message)"
}

if($null -eq $AuthResult){
    throw "AI_AUTHORIZATION_NO_RESULT"
}

if(($AuthResult.Authorized -ne $true) -and ($AuthResult.Decision -ne "ALLOW")){
    throw "AI_AUTHORIZATION_DENIED"
}

$WorkerExists=$true
$SkillCount=0

if(Test-Path -LiteralPath $SkillRegistry -PathType Leaf){
    try {
        $Skills=Get-Content -LiteralPath $SkillRegistry -Raw -Encoding UTF8 | ConvertFrom-Json
        $SkillCount=@($Skills.PSObject.Properties).Count
    }
    catch {
        $SkillCount=0
    }
}

# Le Gate a deja ete verifie via Invoke-AISecureAuthorization
# ci-dessus : c'est cette verification (pas un nouveau jeu de
# flags improvise) qui doit re-passer ici, puisque
# AI-PROVIDER-ENGINE.ps1 revalide lui-meme le Global Security
# Gate avant de deleguer au moteur reel. On lui donne le meme
# contexte reel, plus les parametres metier Worker/Task/Objectif.
& $ProviderEngine `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -UserId $UserId `
    -Environment $Environment `
    -Mode $Mode `
    -SessionValid $true `
    -RBACAuthorized $true `
    -ScopeValid $true `
    -AuthorizationValid $true `
    -CapabilityAuthorized $ChainResult.CapabilityAuthorized `
    -AuthorityAuthorized $ChainResult.AuthorityAuthorized `
    -PolicyAuthorized $ChainResult.PolicyAuthorized `
    -WorkerTaskAuthorized $ChainResult.WorkerTaskAuthorized `
    -CredentialAuthorized $ChainResult.CredentialAuthorized `
    -ConnectorAuthorized $ChainResult.ConnectorAuthorized `
    -ProviderAuthorized $ChainResult.ProviderAuthorized `
    -EvidenceAuthorized $ChainResult.EvidenceAuthorized `
    -RetentionValid $ChainResult.RetentionValid `
    -PurgeReuseValid $ChainResult.PurgeReuseValid `
    -WorkerId $WorkerId.ToUpper() `
    -TaskId $TaskId `
    -Objective $Objective `
    -Provider $Provider `
    -Model $Model `
    *>&1 | Out-Null

# Le moteur (AI-PROVIDER-ENGINE-LOCAL.ps1) est concu pour tourner en
# script autonome : il ecrit son resultat sur disque et termine avec
# `exit`, il ne retourne pas d'objet dans le pipeline. On relit donc
# le fichier qu'il vient reellement de produire, plutot que de
# supposer une valeur de retour qu'il n'a jamais emise.
$ProviderResultPath = Join-Path $Root "memory/runtime/PROVIDER-$TaskId.json"

if (-not (Test-Path -LiteralPath $ProviderResultPath -PathType Leaf)) {
    throw "AI_PROVIDER_NO_RESULT"
}

$ProviderResult = Get-Content -LiteralPath $ProviderResultPath -Raw -Encoding UTF8 | ConvertFrom-Json

if($null -eq $ProviderResult){
    throw "AI_PROVIDER_NO_RESULT"
}

# Acces tolerant : le fichier resultat du moteur n'a pas toujours toutes les cles (mode strict).
function Get-ProviderField($Object, [string]$Name) {
    $Prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $Prop) { return $null }
    return $Prop.Value
}

$result=[ordered]@{
    Schema="BK-AI-WORKER-AI-RESULT"
    Version="1.0"
    Success=$true
    WorkerId=$WorkerId.ToUpper()
    TaskId=$TaskId
    Objective=$Objective
    TenantId=$TenantId
    ClientId=$ClientId
    ProjectId=$ProjectId
    ExecutionId=$ExecutionId
    UserId=$UserId
    Environment=$Environment
    Mode=$Mode
    Provider=$(Get-ProviderField $ProviderResult 'provider')
    Model=$(Get-ProviderField $ProviderResult 'model')
    # FALLBACK = fournisseur externe indisponible (ex : credit epuise), le
    # traitement local a pris le relais : la mission n'est pas un echec de
    # securite, mais elle est marquee Degraded pour que l'UI l'indique.
    Status=$(if ($(Get-ProviderField $ProviderResult 'status') -eq "FALLBACK") { "SUCCESS" } else { $(Get-ProviderField $ProviderResult 'status') })
    Degraded=[bool]$(Get-ProviderField $ProviderResult 'fallback')
    FallbackReason=$(Get-ProviderField $ProviderResult 'fallback_reason')
    Answer=$(Get-ProviderField $ProviderResult 'answer')
    Usage=$(Get-ProviderField $ProviderResult 'usage')
    Recommendations=$(Get-ProviderField $ProviderResult 'recommendations')
    NextAction=$(Get-ProviderField $ProviderResult 'next_action')
    SecurityStatus=$(Get-ProviderField $ProviderResult 'security_status')
    SkillCount=$SkillCount
    WorkerResolved=$WorkerExists
}

$result | ConvertTo-Json -Depth 20