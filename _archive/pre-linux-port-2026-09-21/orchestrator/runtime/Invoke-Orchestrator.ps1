[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Request,

    [Parameter(Mandatory=$true)]
    [string]$TenantId,

    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$ExecutionId,

    [Parameter(Mandatory=$true)]
    [string]$UserId,

    [Parameter(Mandatory=$true)]
    [string]$SessionId,

    [Parameter(Mandatory=$true)]
    [string]$TokenId,

    [Parameter(Mandatory=$true)]
    [string]$Token,

    [Parameter(Mandatory=$true)]
    [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
    [string]$Mode,

    [Parameter(Mandatory=$true)]
    [string]$Environment,

    [ValidateSet("critical","high","normal","low")]
    [string]$Priority = "normal"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
. (Join-Path $Root "core\ai\Get-DefaultProvider.ps1")
$Entry = Join-Path $Root "core\ai\AI-SECURE-ENTRY-GUARD.ps1"
$RuntimeDir = Join-Path $Root "runtime\tasks"
$FullChainResolver = Join-Path $Root "core\runtime\security-gate\Resolve-FullAuthorizationChain.ps1"

if (-not (Test-Path -LiteralPath $Entry -PathType Leaf)) {
    throw "AI_SECURE_ENTRY_MISSING"
}

if (-not (Test-Path -LiteralPath $FullChainResolver -PathType Leaf)) {
    throw "FULL_CHAIN_RESOLVER_MISSING"
}

if (-not (Test-Path -LiteralPath $RuntimeDir -PathType Container)) {
    New-Item -ItemType Directory -Path $RuntimeDir -Force | Out-Null
}

. $Entry
. $FullChainResolver

$Lower = $Request.ToLowerInvariant()

$Worker = $null
$Action = "READ"
$Status = "BLOCKED"
$NextAction = "REQUEST_CLARIFICATION"

# =================================================
# ROUTAGE GENERIQUE (corrige le 2026-09-14) :
# lit orchestrator\worker-routing.json au lieu d'une
# chaine if/elif codee en dur (qui etait fausse : ex.
# "web|develop|code" routait vers ALEX au lieu de LUCAS).
# Ajouter un Worker au JSON suffit desormais a le rendre
# routable ici, sans modifier ce script.
# =================================================
$RoutingConfigPath = Join-Path $Root "orchestrator\worker-routing.json"

# Filtre mots-cles "finance" retire le 2026-09-14 (a la demande de
# Kader) : il empechait DARIO (Worker Finance & Controle de gestion)
# d'etre jamais route, y compris pour de la simple preparation
# (facture, budget). Ce filtre etait redondant avec les protections
# structurelles reelles, qui restent toutes actives independamment du
# routage :
#   - financial_actions:false code en dur dans CAPABILITY-MATRIX.json
#     (globalRules) et dans CHAQUE skill contract de DARIO ;
#   - les connecteurs de paiement (STRIPE, PAYPAL, QUICKBOOKS, XERO)
#     sont individuellement "enabled: false" dans
#     CONTROLLED-CONNECTOR-CATALOG.json — meme routee, une tentative
#     d'usage reel serait bloquee au stage CONNECTOR du Gate ;
#   - LIVE reste desactive globalement.
# Router vers DARIO permet seulement la PREPARATION/analyse (les
# operations catalogue elles-memes sont PREPARE_INVOICE/PREPARE_PAYMENT,
# jamais une execution), qui est exactement son role.
if (Test-Path -LiteralPath $RoutingConfigPath -PathType Leaf) {
    $RoutingConfig = Get-Content -LiteralPath $RoutingConfigPath -Raw | ConvertFrom-Json
    $Excluded = @($RoutingConfig.excluded_from_routing)

    foreach ($WorkerIdProp in $RoutingConfig.workers.PSObject.Properties) {
        $WorkerId = $WorkerIdProp.Name
        if ($Excluded -contains $WorkerId) { continue }

        $Keywords = @($WorkerIdProp.Value.primary)
        $Matched = $false
        foreach ($Keyword in $Keywords) {
            # Limite de mot (pas Contains() brut) : evite qu'un mot-cle
            # court comme "it" corresponde a l'interieur de "site".
            # Corrige le 2026-09-14 apres detection via le test SEOYA/CHLOE.
            # Tolere le pluriel francais simple (+s) sans quoi "paiement"
            # ne matche pas "paiements" (corrige le 2026-09-14).
            if ($Lower -match ('(?<![a-z0-9])' + [regex]::Escape($Keyword) + 's?(?![a-z0-9])')) {
                $Matched = $true; break
            }
        }

        if ($Matched) {
            $Worker = $WorkerIdProp.Value.name
            $Action = "READ"
            $Status = "ROUTED"
            $NextAction = "EXECUTE_SIMULATION"
            break
        }
    }
}

$TaskId = "TASK-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()

# =================================================
# APPLICATION DE LA POLITIQUE D'AUTONOMIE (2026-09-15) :
# core/config/AUTONOMY-POLICY.md est documente depuis le
# 2026-09-14 mais n'etait applique par AUCUN code — un appel
# direct a l'Orchestrateur (hors Chloe) executait n'importe
# quelle action, y compris SEND/PUBLISH/DELETE/EXECUTE qui
# devraient passer par la revue de Chloe. Ferme cet ecart :
# ce chemin SOLO (pas Chloe) refuse desormais toute action a
# risque et redirige vers chloe/Invoke-Chloe-Orchestration.ps1,
# qui a sa propre etape REVIEW. Chloe elle-meme appelle
# Invoke-Worker-AI.ps1 directement (pas ce script), donc ce
# garde-fou ne la bloque jamais — seul le chemin solo est
# concerne.
# =================================================
if ($null -ne $Worker) {
    $DetectedAction = $null
    if ($Lower -match '(?<![a-z0-9])(envoie|envoyer|envoi)s?(?![a-z0-9])') { $DetectedAction = "SEND" }
    elseif ($Lower -match '(?<![a-z0-9])(publie|publier|publication)s?(?![a-z0-9])') { $DetectedAction = "PUBLISH" }
    elseif ($Lower -match '(?<![a-z0-9])(supprime|supprimer|efface|effacer)s?(?![a-z0-9])') { $DetectedAction = "DELETE" }
    elseif ($Lower -match '(?<![a-z0-9])(execute|executer|lance|lancer)s?(?![a-z0-9])') { $DetectedAction = "EXECUTE" }

    if ($null -ne $DetectedAction) {
        $WorkerLower = $Worker.ToLowerInvariant()
        $ContractPath = Join-Path $Root ("workers\" + $WorkerLower + "\contract.json")
        if (Test-Path -LiteralPath $ContractPath -PathType Leaf) {
            $Contract = Get-Content -LiteralPath $ContractPath -Raw | ConvertFrom-Json
            $VerifList = @($Contract.execution.chloeVerificationRequired)
            $NeedsChloe = [bool]($VerifList | Where-Object { $_ -like "*.$DetectedAction" })
            if ($NeedsChloe) {
                $Status = "NEEDS_CHLOE_VERIFICATION"
                $NextAction = "ROUTE_VIA_CHLOE_ORCHESTRATION"
            }
        }
    }
}

if ($Status -eq "NEEDS_CHLOE_VERIFICATION") {
    return [pscustomobject]@{
        Decision = "BLOCK"
        Authorized = $false
        Status = "NEEDS_CHLOE_VERIFICATION"
        Reason = "AUTONOMY_POLICY:Action a risque (SEND/PUBLISH/DELETE/EXECUTE) pour $Worker — doit passer par chloe/Invoke-Chloe-Orchestration.ps1 (etape REVIEW), pas par un appel Orchestrateur solo. Voir core/config/AUTONOMY-POLICY.md."
        Worker = $Worker
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        ExecutionId = $ExecutionId
        UserId = $UserId
        Environment = $Environment
        Mode = $Mode
        NextAction = "ROUTE_VIA_CHLOE_ORCHESTRATION"
    }
}

# =================================================
# RESOLUTION REELLE DE TOUTE LA CHAINE (Capability ->
# PurgeReuse) via la fonction partagee, reutilisee
# aussi par Invoke-Worker-AI.ps1. Voir ce fichier pour
# le detail et les choix documentes par stage.
# =================================================

$CapabilityAuthorized = $false
$AuthorityAuthorized = $false
$PolicyAuthorized = $false
$WorkerTaskAuthorized = $false
$CredentialAuthorized = $false
$ConnectorAuthorized = $false
$ProviderAuthorized = $false
$EvidenceAuthorized = $false
$RetentionValid = $false
$PurgeReuseValid = $false

if ($null -ne $Worker) {
    $ChainResult = Resolve-BKFullAuthorizationChain `
        -Worker $Worker `
        -Action $Action `
        -Description $Request `
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

    $CapabilityAuthorized = $ChainResult.CapabilityAuthorized
    $AuthorityAuthorized = $ChainResult.AuthorityAuthorized
    $PolicyAuthorized = $ChainResult.PolicyAuthorized
    $WorkerTaskAuthorized = $ChainResult.WorkerTaskAuthorized
    $CredentialAuthorized = $ChainResult.CredentialAuthorized
    $ConnectorAuthorized = $ChainResult.ConnectorAuthorized
    $ProviderAuthorized = $ChainResult.ProviderAuthorized
    $EvidenceAuthorized = $ChainResult.EvidenceAuthorized
    $RetentionValid = $ChainResult.RetentionValid
    $PurgeReuseValid = $ChainResult.PurgeReuseValid
}

$AuthParameters = @{
    TokenId = $TokenId
    Token = $Token
    SessionId = $SessionId
    UserId = $UserId
    TenantId = $TenantId
    ClientId = $ClientId
    ProjectId = $ProjectId
    ExecutionId = $ExecutionId
    Action = $Action
    Environment = $Environment
    Mode = $Mode

    CapabilityAuthorized = $CapabilityAuthorized
    AuthorityAuthorized = $AuthorityAuthorized
    PolicyAuthorized = $PolicyAuthorized
    WorkerTaskAuthorized = $WorkerTaskAuthorized
    CredentialAuthorized = $CredentialAuthorized
    ConnectorAuthorized = $ConnectorAuthorized
    ProviderAuthorized = $ProviderAuthorized
    EvidenceAuthorized = $EvidenceAuthorized
    RetentionValid = $RetentionValid
    PurgeReuseValid = $PurgeReuseValid

    DirectProviderExecution = $false
    DirectConnectorExecution = $false
    SecretsPresent = $false
}

try {
    $Security = Invoke-AISecureAuthorization -Parameters $AuthParameters
}
catch {
    [pscustomobject]@{
        Decision = "BLOCK"
        Authorized = $false
        Status = "SECURITY_BLOCKED"
        Reason = $_.Exception.Message
        Worker = $Worker
        TenantId = $TenantId
        ClientId = $ClientId
        ProjectId = $ProjectId
        ExecutionId = $ExecutionId
        UserId = $UserId
        Environment = $Environment
        Mode = $Mode
        NextAction = "SECURITY_REVIEW"
    }

    return
}

if ($Status -eq "HUMAN_REVIEW_REQUIRED") {
    $NextAction = "HUMAN_APPROVAL"
}
elseif ($null -eq $Worker) {
    $Status = "BLOCKED"
    $NextAction = "REQUEST_CLARIFICATION"
}

$Task = [ordered]@{
    TaskId = $TaskId
    Request = $Request
    Worker = $Worker
    Action = $Action
    Priority = $Priority
    Status = $Status
    NextAction = $NextAction

    TenantId = $TenantId
    ClientId = $ClientId
    ProjectId = $ProjectId
    ExecutionId = $ExecutionId
    UserId = $UserId

    Environment = $Environment
    Mode = $Mode

    Authorized = [bool]$Security.Authorized
    SecurityDecision = $Security.Decision
    ContextHash = $Security.ContextHash

    CreatedAtUtc = [DateTime]::UtcNow.ToString("o")
}

# =================================================
# DISPATCH AUTOMATIQUE VERS L'EXECUTION REELLE.
# Si la tache est autorisee et routee vers un Worker,
# on enchaine directement sur Invoke-Worker-AI.ps1
# (meme chaine de securite deja re-verifiee a l'interne
# par ce script) pour produire un vrai resultat, plutot
# que de s'arreter a "tache autorisee" et d'exiger un
# deuxieme appel manuel separe. Si l'execution echoue
# (ex: CONNECTOR non enregistre pour cet outil), la
# tache reste "AUTHORIZED" avec le detail de l'echec —
# ce n'est pas un echec de securite, juste une limite de
# perimetre actuelle honnetement rapportee.
# =================================================

if ($Task.Authorized -eq $true -and $null -ne $Worker) {

    $WorkerAIPath = Join-Path $Root "core\runtime\worker-runtime\Invoke-Worker-AI.ps1"

    if (Test-Path -LiteralPath $WorkerAIPath -PathType Leaf) {
        try {
            # TaskId distinct de celui de la tache de routage : chaque
            # etape de la chaine (Authority/Retention/WorkerTaskAuthority)
            # exige un identifiant unique et refuse un second enregistrement
            # avec le meme TaskId (protection anti-rejeu), donc reutiliser
            # $TaskId ici echouerait systematiquement en DUPLICATE.
            $ExecutionTaskId = "TASK-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()

            $WorkerAIJson = & $WorkerAIPath `
                -WorkerId $Worker `
                -TaskId $ExecutionTaskId `
                -Objective $Request `
                -TenantId $TenantId `
                -ClientId $ClientId `
                -ProjectId $ProjectId `
                -ExecutionId ($ExecutionId + "-EXEC") `
                -UserId $UserId `
                -SessionId $SessionId `
                -TokenId $TokenId `
                -Token $Token `
                -Environment $Environment `
                -Mode $Mode `
                -Provider (Get-DefaultAIProvider) `
                -Model "NONE" 2>&1

            $WorkerAIResult = $WorkerAIJson | ConvertFrom-Json -ErrorAction SilentlyContinue

            if ($null -ne $WorkerAIResult -and $WorkerAIResult.Status -eq "SUCCESS") {
                $Task.Status = "EXECUTED"
                $Task.NextAction = "REVIEW_RESULT"
                $Task["Result"] = $WorkerAIResult
            }
            else {
                $Task["ExecutionNote"] = "Tache autorisee mais execution non aboutie : " + ($WorkerAIJson -join ' ')
            }
        }
        catch {
            $Task["ExecutionNote"] = "Tache autorisee mais execution bloquee : $($_.Exception.Message)"
        }
    }
}

$TaskFile = Join-Path $RuntimeDir "$TaskId.json"

[System.IO.File]::WriteAllText(
    $TaskFile,
    ($Task | ConvertTo-Json -Depth 10),
    [System.Text.Encoding]::UTF8
)

[pscustomobject]$Task