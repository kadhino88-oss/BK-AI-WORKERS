[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Request,
    [Parameter(Mandatory=$true)][string]$TenantId,
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$ExecutionId,
    [Parameter(Mandatory=$true)][string]$UserId,
    [Parameter(Mandatory=$true)][string]$SessionId,
    [Parameter(Mandatory=$true)][string]$TokenId,
    [Parameter(Mandatory=$true)][string]$Token,
    [ValidateSet("SIMULATION","SANDBOX","CERTIFICATION","PILOT","LIVE")]
    [string]$Mode = "SIMULATION",
    [string]$Environment = "SIMULATION",

    # PARALLEL (par defaut) : tous les Workers selectionnes recoivent la
    # meme demande et travaillent independamment (pattern D du doc
    # officiel, section 22).
    # CHAIN : les Workers selectionnes sont executes dans l'ORDRE OU ILS
    # SONT LISTES dans orchestrator\worker-routing.json (pas un ordre
    # devine), chacun recevant en plus de la demande originale la
    # reponse du Worker precedent (pattern C, ex. AMINA -> MAYA -> EMMA
    # -> SEOYA). Ajoute le 2026-09-14.
    [ValidateSet("PARALLEL","CHAIN")]
    [string]$CollaborationMode = "PARALLEL",

    # PlanOnly : s'arrete juste apres PLAN/ASSIGN (retourne les Workers
    # selectionnes) SANS lancer EXECUTE. Ajoute le 2026-09-15 pour
    # l'Onboarding : permet une vraie etape "Chloe propose une equipe"
    # que l'utilisateur valide AVANT que quoi que ce soit s'execute —
    # pas une mise en scene apres coup d'un resultat deja produit.
    [switch]$PlanOnly
)

# =====================================================================
# CHLOE — Orchestration multi-Workers (2026-09-14, pipeline complet
# le 2026-09-15)
#
# Chloe n'execute jamais rien elle-meme : elle SELECTIONNE les Workers
# pertinents (via orchestrator\worker-routing.json, comme le routage
# simple d'Invoke-Orchestrator.ps1 mais SANS s'arreter au premier
# match), delegue CHACUN via le meme chemin d'autorisation reel a
# 14 etapes que n'importe quel appel direct (aucun raccourci, aucun
# Gate contourne), verifie chaque resultat, assemble une synthese, et
# memorise la mission.
#
# Implemente le pipeline officiel (BK-AI-WORKERS-STRUCTURE-OFFICIELLE-
# 18-WORKERS.md, section 0) :
#   REQUEST    -> parametre $Request
#   UNDERSTAND -> match mots-cles sur worker-routing.json (pas encore
#                 de comprehension LLM reelle — OpenAI sans credits au
#                 2026-09-15, voir limite ci-dessous)
#   PLAN       -> selection des Workers (+ ordre si CHAIN)
#   ASSIGN     -> $SelectedWorkers
#   EXECUTE    -> boucle de delegation via Invoke-Worker-AI.ps1
#   REVIEW     -> verification par resultat (reponse non vide, aucune
#                 fuite financiere/externe)
#   COMBINE    -> assemblage des resultats revus
#   DELIVER    -> $FinalSynthesis (texte unique pour Kader)
#   LEARN      -> ecriture memoire via memory/engine/Memory-Access.ps1
#
# LIMITE HONNETE : UNDERSTAND reste un simple matching de mots-cles
# (comme Invoke-Orchestrator.ps1), pas une vraie comprehension de
# langage — une comprehension plus fine demanderait un vrai appel LLM
# (OpenAI, bloque par manque de credits au 2026-09-15). DELIVER
# concatene les reponses des Workers (elles-memes des reponses locales
# de secours tant qu'OpenAI n'a pas de credits) plutot que de generer
# une synthese redigee par une IA — ce sera possible des que le
# provider reel repondra.
# =====================================================================

$ErrorActionPreference = "Stop"
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }

$WorkerAIPath = Join-Path $Root "core/runtime/worker-runtime/Invoke-Worker-AI.ps1"
. (Join-Path $Root "core/ai/Get-DefaultProvider.ps1")
. (Join-Path $Root "core/ai/BK-Secret.ps1")
$RoutingConfigPath = Join-Path $Root "orchestrator/worker-routing.json"

if (-not (Test-Path -LiteralPath $WorkerAIPath -PathType Leaf)) {
    throw "WORKER_AI_MISSING"
}
if (-not (Test-Path -LiteralPath $RoutingConfigPath -PathType Leaf)) {
    throw "ROUTING_CONFIG_MISSING"
}

# =====================================================================
# REPLI IA REEL POUR UNDERSTAND (2026-09-24, signale par Kader avec un
# cas reel : "je veux gerer mes reseaux sociaux" ne matchait aucun mot-
# cle exact malgre un sens evident, et rien ne fonctionne dans une
# langue autre que le francais). Le matching de mots-cles reste la
# premiere passe (rapide, gratuite, deterministe) ; ce repli n'est
# appele QUE quand elle ne trouve strictement aucun Worker — un vrai
# appel Claude (meme cle/API que les Workers) route semantiquement,
# dans la langue du client, ou repond directement si aucun Worker n'est
# necessaire (salutation, message general). Chloe continue de
# n'executer elle-meme aucune action : ce repli ne fait qu'ameliorer
# QUELS Workers sont choisis (ou repondre par du texte pur) — la
# delegation reelle passe toujours par le meme Invoke-Worker-AI.ps1 et
# la meme chaine d'autorisation, sans aucun raccourci.
# =====================================================================
function Invoke-BKChloeAIRouting {
    param(
        [Parameter(Mandatory=$true)][string]$UserRequest,
        [Parameter(Mandatory=$true)]$RoutingConfig,
        [Parameter(Mandatory=$true)][array]$Excluded
    )
    if (-not (Test-BKSecret -Name "anthropic")) { return $null }
    try {
        $PlainKey = Get-BKSecretValue -Name "anthropic"
        if ([string]::IsNullOrWhiteSpace($PlainKey)) { return $null }

        $WorkerLines = @()
        foreach ($WorkerIdProp in $RoutingConfig.workers.PSObject.Properties) {
            if ($Excluded -contains $WorkerIdProp.Name) { continue }
            $Kw = ($WorkerIdProp.Value.primary -join ", ")
            $WorkerLines += "- $($WorkerIdProp.Name) : $Kw"
        }
        $WorkerList = $WorkerLines -join "`n"

        $RouteLangHint = ""
        if ($env:BK_REPLY_LANG -match '^[A-Za-z]+$') { $RouteLangHint = "`nThe client's message is written in $($env:BK_REPLY_LANG): any direct_reply must be in $($env:BK_REPLY_LANG)." }
        $SystemPrompt = @"
You are the internal router of Chloe, the orchestrator of BK-AI-WORKERS. A client writes a message, in any language in the world. Your only task: decide which of the Workers below really match the request, OR answer yourself only when no Worker is needed.

Available Workers (identifier : specialty keywords):
$WorkerList

Rules:
- Any concrete request or question - even a general one, personal advice, or something outside business - goes to the closest Worker. Never refuse and never send the client elsewhere. If nothing fits better, use "noah" (generalist assistant) when it is in the list.
- Use direct_reply ONLY for a greeting, a thank-you, an extremely vague message (e.g. "help"), or a question about the BK-AI-WORKERS service itself (what you can do, plans, how it works).
- If the message fits several Workers, list them all.

Reply ONLY with a strict JSON object, no text around it, no markdown fences, in this exact format:
{"workers": ["id1","id2"], "direct_reply": null}
or, when no Worker is needed:
{"workers": [], "direct_reply": "<your answer, in the SAME language as the client's message, warm, direct, 1 to 3 short sentences>"}

The values of "workers" must be EXACTLY identifiers from the list above (lowercase), never invented.$RouteLangHint
"@

        # Le routeur est un appel JSON-seul (300 jetons max) : on n'y ajoute PAS le guide complet de Chloe (revue 2026-10-11 :
        # il contredisait la regle "JSON uniquement" et pouvait faire echouer tout le routage). Seulement les tarifs, pour
        # qu'une question sur les plans ne soit jamais inventee ni attribuee a la mauvaise marque.
        $SystemPrompt = $SystemPrompt + "`n`nPRIX (questions sur les plans, a repondre dans direct_reply) : plateforme BK-AI-WORKERS = plan gratuit, Starter 39, Business 99, Pro 139, Scale 449 CHF par mois. BK Entreprise est l'agence parente : devis uniquement, jamais de tarifs BK Entreprise. N'invente aucun autre chiffre.`nReply ONLY with the strict JSON object described above."

        $BodyObj = [ordered]@{
            model      = "claude-haiku-4-5-20251001"
            max_tokens = 300
            system     = $SystemPrompt
            messages   = @(@{ role = "user"; content = $UserRequest })
        }
        $Headers = @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" }
        $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
            -Headers $Headers -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($BodyObj | ConvertTo-Json -Depth 10))) -TimeoutSec 20

        $TextBlock = $Response.content | Where-Object { $_.type -eq "text" } | Select-Object -First 1
        if (-not $TextBlock) { return $null }
        $Raw = $TextBlock.text.Trim()
        $Raw = $Raw -replace '^```json\s*', '' -replace '^```\s*', '' -replace '```\s*$', ''
        $Parsed = $Raw | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($null -eq $Parsed) { return $null }

        $ValidIds = @($RoutingConfig.workers.PSObject.Properties.Name | Where-Object { $Excluded -notcontains $_ })
        $Chosen = @()
        foreach ($Id in @($Parsed.workers)) {
            $IdLower = $Id.ToString().ToLowerInvariant()
            if ($ValidIds -contains $IdLower) {
                $Prop = $RoutingConfig.workers.PSObject.Properties | Where-Object { $_.Name -eq $IdLower }
                if ($Prop) { $Chosen += $Prop.Value.name }
            }
        }
        return [pscustomobject]@{ Workers = $Chosen; DirectReply = [string]$Parsed.direct_reply }
    }
    catch {
        return $null
    }
}

$Lower = $Request.ToLowerInvariant()

# =================================================
# SELECTION : contrairement au routage simple (un seul
# Worker, premier match), Chloe retient TOUS les Workers
# dont au moins un mot-cle correspond a la demande.
# =================================================
$RoutingConfig = Get-Content -LiteralPath $RoutingConfigPath -Raw | ConvertFrom-Json
$Excluded = @($RoutingConfig.excluded_from_routing)

$SelectedWorkers = @()
foreach ($WorkerIdProp in $RoutingConfig.workers.PSObject.Properties) {
    if ($Excluded -contains $WorkerIdProp.Name) { continue }
    $Keywords = @($WorkerIdProp.Value.primary)
    foreach ($Keyword in $Keywords) {
        # Limite de mot, pas Contains() brut — voir la meme correction
        # dans Invoke-Orchestrator.ps1 (2026-09-14).
        # Tolere le pluriel francais simple (+s), meme correction que
        # Invoke-Orchestrator.ps1 (2026-09-14).
        if ($Lower -match ('(?<![a-z0-9])' + [regex]::Escape($Keyword) + 's?(?![a-z0-9])')) {
            $SelectedWorkers += $WorkerIdProp.Value.name
            break
        }
    }
}

if ($SelectedWorkers.Count -eq 0) {
    # Repli IA reel avant d'abandonner (voir bloc Invoke-BKChloeAIRouting
    # plus haut) : comprend la demande semantiquement, dans n'importe
    # quelle langue, et choisit les vrais Workers ou repond directement.
    $AIRouting = Invoke-BKChloeAIRouting -UserRequest $Request -RoutingConfig $RoutingConfig -Excluded $Excluded

    if ($null -ne $AIRouting -and $AIRouting.Workers.Count -gt 0) {
        # Des Workers reels ont ete identifies semantiquement : on
        # rejoint le flux normal de delegation plus bas (pas de return
        # ici), exactement comme si le matching de mots-cles les avait
        # trouves directement.
        $SelectedWorkers = $AIRouting.Workers
    }
    elseif ($null -ne $AIRouting -and -not [string]::IsNullOrWhiteSpace($AIRouting.DirectReply)) {
        return [pscustomobject]@{
            Orchestrator = "CHLOE"
            Request      = $Request
            SelectedWorkers = @()
            Status       = "SUCCESS"
            NextAction   = "REVIEW_RESULT"
            Results      = @()
            FinalSynthesis = $AIRouting.DirectReply
        }
    }
    else {
        # Repli du repli : l'appel IA a echoue (pas de credit, reseau,
        # reponse invalide...) — jamais un crash ni un silence, un texte
        # fixe honnete dans le ton de Chloe (identity.json : chaleureuse,
        # directe, courte), utile pour une salutation comme pour une
        # demande trop vague.
        $Greetings = @("bonjour","bonsoir","salut","bjr","bsr","coucou","cc","hello","hi","hey","yo")
        $NormalizedRequest = $Lower.Trim(" .!?")
        $IsGreeting = $Greetings -contains $NormalizedRequest

        $GreetingSynthesis = "Bonjour ! Je suis Chloe. Decrivez-moi votre objectif (ex. : `"redige un email de prospection`" ou `"analyse mes ventes du mois`") et je compose l'equipe de Workers qu'il faut pour le realiser."
        $ClarificationSynthesis = "Je n'ai pas identifie de Worker correspondant a cette demande. Pouvez-vous la reformuler avec le metier ou le resultat attendu (ex. : prospection, contenu, design, developpement, support...) ?"

        return [pscustomobject]@{
            Orchestrator = "CHLOE"
            Request      = $Request
            SelectedWorkers = @()
            Status       = "NO_WORKER_MATCHED"
            NextAction   = "REQUEST_CLARIFICATION"
            Results      = @()
            FinalSynthesis = if ($IsGreeting) { $GreetingSynthesis } else { $ClarificationSynthesis }
        }
    }
}

if ($PlanOnly) {
    return [pscustomobject]@{
        Orchestrator    = "CHLOE"
        Request         = $Request
        SelectedWorkers = $SelectedWorkers
        Status          = "PLANNED"
        NextAction      = "AWAITING_VALIDATION"
    }
}

# =================================================
# DELEGATION : chaque Worker selectionne recoit sa propre
# tache, avec son propre TaskId/ExecutionId uniques (la
# chaine anti-rejeu refuse un second enregistrement avec
# le meme TaskId), et passe par le MEME chemin d'autorisation
# reel que n'importe quel appel direct.
#
# En mode CHAIN, l'ordre d'execution est celui de
# $SelectedWorkers (lui-meme l'ordre des proprietes dans
# worker-routing.json) — deterministe, pas devine a la volee.
# Si un maillon de la chaine ne reussit pas (Status != SUCCESS),
# la chaine s'arrete la (les maillons suivants ne sont PAS
# executes avec un contexte incomplet) et le statut global
# reflete l'arret anticipe.
# =================================================
$Results = @()
$ChainContext = $null
$ChainStopped = $false

foreach ($WorkerName in $SelectedWorkers) {
    if ($CollaborationMode -eq "CHAIN" -and $ChainStopped) {
        $Results += [pscustomobject]@{
            Worker = $WorkerName
            TaskId = $null
            Status = "SKIPPED_CHAIN_STOPPED"
            Result = $null
        }
        continue
    }

    $TaskId = "TASK-" + [guid]::NewGuid().ToString("N").ToUpperInvariant()
    $Objective = $Request
    if ($CollaborationMode -eq "CHAIN" -and $null -ne $ChainContext) {
        $Objective = "$Request`n`n[Contexte transmis par le Worker precedent dans la chaine Chloe] : $ChainContext"
    }

    try {
        if ($env:CHLOE_DEBUG_CHAIN -eq "1") { Write-Host "[DEBUG] $WorkerName Objective = $Objective" -ForegroundColor Magenta }
        $WorkerAIJson = & $WorkerAIPath `
            -WorkerId $WorkerName `
            -TaskId $TaskId `
            -Objective $Objective `
            -TenantId $TenantId `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -ExecutionId ($ExecutionId + "-CHLOE-" + $WorkerName) `
            -UserId $UserId `
            -SessionId $SessionId `
            -TokenId $TokenId `
            -Token $Token `
            -Environment $Environment `
            -Mode $Mode `
            -Provider (Get-DefaultAIProvider) `
            -Model "NONE" 2>&1

        $WorkerAIResult = $WorkerAIJson | ConvertFrom-Json -ErrorAction SilentlyContinue
        $ThisStatus = if ($null -ne $WorkerAIResult) { $WorkerAIResult.Status } else { "NO_RESULT" }

        $Results += [pscustomobject]@{
            Worker = $WorkerName
            TaskId = $TaskId
            Status = $ThisStatus
            Result = $WorkerAIResult
        }

        if ($CollaborationMode -eq "CHAIN") {
            if ($ThisStatus -eq "SUCCESS" -and $null -ne $WorkerAIResult.Answer) {
                $ChainContext = $WorkerAIResult.Answer
            }
            else {
                $ChainStopped = $true
            }
        }
    }
    catch {
        $Results += [pscustomobject]@{
            Worker = $WorkerName
            TaskId = $TaskId
            Status = "ERROR"
            Result = $null
            Error  = $_.Exception.Message
        }
        if ($CollaborationMode -eq "CHAIN") { $ChainStopped = $true }
    }
}

# =================================================
# REVIEW : Chloe verifie chaque resultat avant de l'inclure
# dans la synthese — ne fait pas juste confiance au Status
# du Worker. Verifie : reponse non vide, aucune fuite
# financiere/externe (principe de verite du contrat commun,
# meme sans logique IA de relecture pour l'instant).
# Etape du pipeline officiel REQUEST->UNDERSTAND->PLAN->
# ASSIGN->EXECUTE->REVIEW->COMBINE->DELIVER->LEARN,
# ajoutee le 2026-09-15 (etait declaree comme skill RESULT_REVIEW
# mais sans logique derriere jusqu'ici).
# =================================================
foreach ($R in $Results) {
    if ($R.Status -ne "SUCCESS" -or $null -eq $R.Result) {
        $R | Add-Member -NotePropertyName Reviewed -NotePropertyValue $false -Force
        $R | Add-Member -NotePropertyName ReviewNote -NotePropertyValue "Pas de resultat SUCCESS a revoir." -Force
        continue
    }
    $Answer = $R.Result.Answer
    $HasFinancialFlag = ($R.Result.PSObject.Properties.Name -contains "financial_actions") -and ($R.Result.financial_actions -eq $true)
    $HasExternalFlag = ($R.Result.PSObject.Properties.Name -contains "external_actions") -and ($R.Result.external_actions -eq $true)

    if ([string]::IsNullOrWhiteSpace($Answer)) {
        $R | Add-Member -NotePropertyName Reviewed -NotePropertyValue $false -Force
        $R | Add-Member -NotePropertyName ReviewNote -NotePropertyValue "Reponse vide — rejetee par la revue Chloe." -Force
    }
    elseif ($HasFinancialFlag -or $HasExternalFlag) {
        $R | Add-Member -NotePropertyName Reviewed -NotePropertyValue $false -Force
        $R | Add-Member -NotePropertyName ReviewNote -NotePropertyValue "Marqueur financial_actions/external_actions actif — bloque par la revue Chloe (ne doit jamais arriver hors DARIO/paiement)." -Force
    }
    else {
        $R | Add-Member -NotePropertyName Reviewed -NotePropertyValue $true -Force
        $R | Add-Member -NotePropertyName ReviewNote -NotePropertyValue "OK." -Force
    }
}

# =================================================
# COMBINE + DELIVER : assemble une synthese unique et
# lisible pour Kader, uniquement a partir des resultats qui
# ont passe la revue — jamais une synthese "succes" si les
# Workers delegues n'ont pas reellement reussi.
# =================================================
$RealResults = @($Results | Where-Object { $_.Status -ne "SKIPPED_CHAIN_STOPPED" })
$ReviewedOk = @($RealResults | Where-Object { $_.Reviewed -eq $true })
$AllSucceeded = ($RealResults.Count -gt 0) -and ($ReviewedOk.Count -eq $RealResults.Count)
$AnySucceeded = [bool]$ReviewedOk

$OverallStatus = if ($AllSucceeded -and -not $ChainStopped) { "SUCCESS" }
                 elseif ($AnySucceeded) { "PARTIAL_SUCCESS" }
                 else { "BLOCKED" }

$SynthesisParts = @()
foreach ($R in $ReviewedOk) {
    $SynthesisParts += "[$($R.Worker)] $($R.Result.Answer)"
}
$FinalSynthesis = if ($SynthesisParts.Count -gt 0) {
    ($SynthesisParts -join "`n`n")
} else {
    "Aucun resultat verifie a livrer pour cette demande."
}

# =================================================
# LEARN : depose un resume de la mission dans la memoire
# structuree (memory/data/) pour que les prochaines demandes
# similaires en beneficient — via le vrai moteur memoire
# (Memory-Access.ps1), pas un fichier ad-hoc.
# =================================================
$MemoryEngine = Join-Path $Root "memory/engine/Memory-Access.ps1"
$MemoryRuntimeDir = Join-Path $Root "memory/runtime"
$LearnStatus = "SKIPPED"

if (Test-Path -LiteralPath $MemoryEngine -PathType Leaf) {
    try {
        $CtxId = "CTX-CHLOE-LEARN-" + [guid]::NewGuid().ToString("N").Substring(0,10)
        $Ctx = [ordered]@{
            context_id = $CtxId
            client_id = $ClientId
            project_id = $ProjectId
            worker_id = "CHLOE"
            task_id = $ExecutionId
            objective = "LEARN (pipeline officiel) — memoriser le resultat d'une mission Chloe"
            scope = @{ client = $true; project = $true; worker = $true }
            permissions = @{ read = $true; write = $true; external_actions = $false; financial_actions = $false }
            memory = @{ global = @(); client = @(); project = @(); worker = @(); task = @() }
            created_at = (Get-Date).ToUniversalTime().ToString("o")
            updated_at = (Get-Date).ToUniversalTime().ToString("o")
        }
        if (-not (Test-Path -LiteralPath $MemoryRuntimeDir)) { New-Item -ItemType Directory -Path $MemoryRuntimeDir -Force | Out-Null }
        $Ctx | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $MemoryRuntimeDir "$CtxId.json") -Encoding UTF8

        $MemoryValue = "Demande: $Request`nWorkers: $($SelectedWorkers -join ', ')`nMode: $CollaborationMode`nStatut: $OverallStatus`nSynthese: $FinalSynthesis"
        $MemoryKey = "mission-" + $ExecutionId.Replace(":", "-")
        & $MemoryEngine -Action WRITE -ClientId $ClientId -ProjectId $ProjectId -WorkerId "CHLOE" -MemoryKey $MemoryKey -Value $MemoryValue | Out-Null
        $LearnStatus = "WRITTEN"
    }
    catch {
        $LearnStatus = "ERROR: " + $_.Exception.Message
    }
}

return [pscustomobject]@{
    Orchestrator      = "CHLOE"
    Request           = $Request
    CollaborationMode = $CollaborationMode
    SelectedWorkers   = $SelectedWorkers
    Status            = $OverallStatus
    NextAction        = if ($OverallStatus -eq "SUCCESS") { "REVIEW_RESULT" } else { "HUMAN_REVIEW_REQUIRED" }
    Results           = $Results
    FinalSynthesis    = $FinalSynthesis
    LearnStatus       = $LearnStatus
}
