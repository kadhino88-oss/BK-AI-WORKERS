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

    # PARALLEL (par defaut) : sans decoupage par le routeur a modele (repli par mots-cles), tous les Workers selectionnes recoivent la meme
    # demande et travaillent independamment (pattern D du doc officiel, section 22).
    # CHAIN : repli par mots-cles seulement : les Workers sont executes dans l'ORDRE OU ILS SONT LISTES dans orchestrator\worker-routing.json,
    # chacun recevant en plus de la demande originale la reponse du Worker precedent (pattern C, ex. AMINA -> MAYA -> EMMA -> SEOYA).
    # Quand le routeur a modele decoupe la demande, ce sont les dependances du plan (dependsOn) qui decident : parallele ou sequence, par sous-tache.
    [ValidateSet("PARALLEL","CHAIN")]
    [string]$CollaborationMode = "PARALLEL",

    # PlanOnly : s'arrete juste apres PLAN/ASSIGN (retourne les Workers selectionnes) SANS lancer EXECUTE. Ajoute le 2026-09-15 pour
    # l'Onboarding : permet une vraie etape "Chloe propose une equipe" que l'utilisateur valide AVANT que quoi que ce soit s'execute.
    [switch]$PlanOnly,

    # EmitPlan (2026-10-19) : renvoie le plan decoupe (sous-taches, Worker, dependances, droits appliques) SANS rien executer. Pour le moteur de
    # projets et les outils : Status PLAN_EMITTED.
    [switch]$EmitPlan
)

# =====================================================================
# CHLOE — Orchestration multi-Workers (2026-09-14, pipeline complet le 2026-09-15, delegation a tous les Workers le 2026-10-19)
#
# Chloe n'execute jamais rien elle-meme : elle DECOUPE la demande, CHOISIT les Workers (parmi les 17, sans autre restriction que le forfait et les
# credits du client), delegue CHACUN via le meme chemin d'autorisation reel a 14 etapes que n'importe quel appel direct (aucun raccourci, aucun
# Gate contourne), fait relayer les resultats d'un Worker au suivant, verifie, assemble une synthese qui dit qui a fait quoi, et memorise la mission.
#
#   REQUEST    -> parametre $Request
#   UNDERSTAND -> routeur a modele (chloe/Chloe-Router.ps1) : plan de sous-taches au schema dur ; repli : mots-cles (orchestrator\worker-routing.json)
#   PLAN       -> sous-taches, dependances, droits du client (BK_ALLOWED_WORKERS) et credits (BK_MAX_WORKERS) appliques PAR LE CODE
#   ASSIGN     -> $SelectedWorkers
#   EXECUTE    -> chloe/Chloe-Executor.ps1 : graphe de dependances, parallele borne, relais, delais, panne partielle
#   REVIEW     -> verification par resultat (reponse non vide, aucune fuite financiere/externe) + coherence entre Workers (facultative)
#   COMBINE    -> chloe/Chloe-Consolidate.ps1 : qui a fait quoi, fichiers, actions a valider, ce qui manque
#   DELIVER    -> $FinalSynthesis (texte) + Sections (par Worker, pour l'interface)
#   LEARN      -> ecriture memoire via memory/engine/Memory-Access.ps1
#
# Interrupteurs : BK_CHLOE_PLANNER=0 (routage par mots-cles et ancien repli IA, comme avant le chantier), BK_CHLOE_EXECUTOR=inline (les Workers
# tournent dans ce processus, un par un). Reglages : BK_CHLOE_PARALLEL (2), BK_CHLOE_SLOTS_GLOBAL (3), BK_CHLOE_DEADLINE_SEC (535).
# Voir docs/CHLOE-DELEGATION.md.
# =====================================================================

$ErrorActionPreference = "Stop"
$RunStart = Get-Date
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }

$WorkerAIPath = Join-Path $Root "core/runtime/worker-runtime/Invoke-Worker-AI.ps1"
. (Join-Path $Root "core/ai/Get-DefaultProvider.ps1")
. (Join-Path $Root "core/ai/BK-Secret.ps1")
foreach ($Helper in @("Chloe-Common.ps1", "Chloe-Router.ps1", "Chloe-Executor.ps1", "Chloe-Consolidate.ps1", "Chloe-Consistency.ps1")) { . (Join-Path $PSScriptRoot $Helper) }
$RoutingConfigPath = Join-Path $Root "orchestrator/worker-routing.json"

if (-not (Test-Path -LiteralPath $WorkerAIPath -PathType Leaf)) {
    throw "WORKER_AI_MISSING"
}
if (-not (Test-Path -LiteralPath $RoutingConfigPath -PathType Leaf)) {
    throw "ROUTING_CONFIG_MISSING"
}

# =====================================================================
# ANCIEN REPLI IA (2026-09-24), conserve pour BK_CHLOE_PLANNER=0 : renvoie des identifiants de Workers, ou repond directement. Le routeur a
# modele (Chloe-Router.ps1) le remplace par defaut. Memes regles qu'avant ; seul le modele est maintenant un parametre.
# =====================================================================
function Invoke-BKChloeAIRouting {
    param(
        [Parameter(Mandatory=$true)][string]$UserRequest,
        [Parameter(Mandatory=$true)]$RoutingConfig,
        [Parameter(Mandatory=$true)][array]$Excluded,
        # Offre "Worker a l'unite" : Workers embauches par le client (null = tous). Le routeur les prefere pour une demande generale ou
        # ambigue, et ne choisit un autre Worker que si la demande releve clairement de sa specialite (Chloe repondra alors WORKER_NOT_INCLUDED).
        $PreferredIds = $null,
        [string]$Model = "claude-haiku-4-5-20251001"
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
        if ($null -ne $PreferredIds) {
            $HiredText = if (@($PreferredIds).Count -gt 0) { (@($PreferredIds) -join ", ") } else { "(none)" }
            $SystemPrompt = $SystemPrompt + "`n`nThis client has hired ONLY these Workers: $HiredText. For a general, ambiguous or off-topic request, choose among them (never a Worker outside this list as a fallback). Choose a Worker outside this list only when the request clearly belongs to that Worker's specialty."
        }

        # Le routeur est un appel JSON-seul (300 jetons max) : on n'y ajoute PAS le guide complet de Chloe (revue 2026-10-11 :
        # il contredisait la regle "JSON uniquement" et pouvait faire echouer tout le routage). Seulement les tarifs.
        $SystemPrompt = $SystemPrompt + "`n`nPRIX (questions sur les plans, a repondre dans direct_reply) : plateforme BK-AI-WORKERS, en CHF par mois (annuel = 10 mois) : Essai gratuit 3 jours (15 credits) ; Solo 29 (1 Worker au choix, 250 credits) ; Trio 59 (3 Workers au choix + Chloe, 500 credits) ; Equipe 99 (tous les Workers + Chloe, 900 credits) ; Pro 139 (1250 credits) ; Scale 449 (4000 credits) ; Enterprise sur devis (plafond de credits fixe par contrat). Starter et Business ne sont plus vendus. Chaque forfait est un quota MENSUEL fixe, jamais illimite : quota atteint = forfait superieur, sans recharge ni depassement facture. BK Entreprise est l'agence parente : devis uniquement, jamais de tarifs BK Entreprise. N'invente aucun autre chiffre.`nReply ONLY with the strict JSON object described above."

        $BodyObj = [ordered]@{
            model      = $Model
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

# ---------------------------------------------------------------------
# Contexte de la demande
# ---------------------------------------------------------------------
$Lower = $Request.ToLowerInvariant()
$RoutingConfig = Get-Content -LiteralPath $RoutingConfigPath -Raw | ConvertFrom-Json
$Excluded = @($RoutingConfig.excluded_from_routing)
# Offre "Worker a l'unite" (2026-10-12) : BK_ALLOWED_WORKERS (pose par dashboard/server.py ou par le moteur d'automatisation) = Workers
# embauches par le client, separes par des virgules ; "-" = aucun ; absente = tous les Workers. Chloe ne delegue qu'a ces Workers.
# C'est la SEULE source des droits : le plan du modele est filtre par ce code, jamais l'inverse.
$AllowedWorkers = Get-BKChloeAllowedWorkers
$Lang = Get-BKChloeReplyLang -Request $Request
$L = Get-BKChloeLabels -Lang $Lang
$Cards = Get-BKChloeCards -Root $Root -RoutingConfig $RoutingConfig
$PlannerOn = ($env:BK_CHLOE_PLANNER -ne "0")
$ProjectsEnabled = ([string]$env:BK_PROJECTS -match '^(?i)(1|true|yes|on)$')
$Level = if ($env:BK_MISSION_LEVEL -match '^[a-z]{3,20}$') { [string]$env:BK_MISSION_LEVEL } else { "" }
$ChloeUsage = @()

function Get-BKChloeWorkerName {
    # Nom de routage (majuscules, comme avant) d'un identifiant de Worker.
    param([string]$Id)
    $P = $RoutingConfig.workers.PSObject.Properties[$Id]
    if ($P -and $P.Value.name) { return [string]$P.Value.name }
    return $Id.ToUpperInvariant()
}

function New-BKChloeDirectResult {
    param([string]$Text, [string]$PlanSource)
    return [pscustomobject]@{
        Orchestrator = "CHLOE"; Request = $Request; SelectedWorkers = @(); Status = "SUCCESS"; NextAction = "REVIEW_RESULT"
        Results = @(); FinalSynthesis = $Text; PlanSource = $PlanSource
    }
}

# =================================================
# UNDERSTAND + PLAN : le routeur a modele decoupe la demande en sous-taches (un Worker chacune, avec ses dependances). Sans cle, sans reponse
# valide apres deux essais, ou avec BK_CHLOE_PLANNER=0 : l'ancien routage par mots-cles (tous les Workers retenus recoivent la meme demande).
# =================================================
$Plan = $null
$PlanSource = "keywords"
$RouteErrors = @()
if ($PlannerOn) {
    $Route = Invoke-BKChloeRoute -Request $Request -RoutingConfig $RoutingConfig -Root $Root -Cards $Cards -Allowed $AllowedWorkers -ProjectsEnabled $ProjectsEnabled -Lang $Lang
    $ChloeUsage += @($Route.Usage)
    $RouteErrors = @($Route.Errors)
    if ($Route.Plan) { $Plan = $Route.Plan; $PlanSource = "model" }
}

if ($null -ne $Plan -and $Plan.mode -eq "direct_reply") {
    return (New-BKChloeDirectResult -Text ([string]$Plan.directReply) -PlanSource "model")
}

if ($null -eq $Plan) {
    $Ids = @(Get-BKChloeKeywordWorkers -Request $Request -RoutingConfig $RoutingConfig)
    if ($Ids.Count -eq 0 -and -not $PlannerOn) {
        # Repli IA reel de l'ancien routage (voir Invoke-BKChloeAIRouting plus haut).
        $AIRouting = Invoke-BKChloeAIRouting -UserRequest $Request -RoutingConfig $RoutingConfig -Excluded $Excluded -PreferredIds $AllowedWorkers
        if ($null -ne $AIRouting -and $AIRouting.Workers.Count -gt 0) {
            $Ids = @($AIRouting.Workers | ForEach-Object { ([string]$_).ToLowerInvariant() })
            $PlanSource = "legacy-ai"
        }
        elseif ($null -ne $AIRouting -and -not [string]::IsNullOrWhiteSpace($AIRouting.DirectReply)) {
            return (New-BKChloeDirectResult -Text $AIRouting.DirectReply -PlanSource "legacy-ai")
        }
    }
    if ($Ids.Count -eq 0) {
        # Repli du repli : aucune comprehension possible (pas de credit, reseau, reponse invalide...) — jamais un crash ni un silence, un texte
        # fixe honnete dans le ton de Chloe (identity.json : chaleureuse, directe, courte), utile pour une salutation comme pour une demande vague.
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
    $Plan = New-BKChloeSimplePlan -Request $Request -WorkerIds $Ids -Source $PlanSource -Chain:($CollaborationMode -eq "CHAIN")
}

# =================================================
# DROITS DU CLIENT (appliques par le code, jamais par le modele) : seuls les Workers inclus dans son forfait travaillent. Les sous-taches des
# autres sont retirees et NOMMEES (NotIncludedWorkers) avec ce qui leur revenait et l'offre d'embauche ; aucune mission n'est lancee pour eux, donc
# aucun credit consomme. Forfait Equipe, Pro, Scale, Enterprise, Essai : les 17 Workers. Trio : les 3 embauches. Solo : pas de Chloe (refus en amont).
# =================================================
$KeptSpecs = @()
$NotIncludedSpecs = @()
foreach ($Spec in @($Plan.subtasks)) {
    if ($null -eq $AllowedWorkers -or ($AllowedWorkers -contains [string]$Spec.worker)) { $KeptSpecs += $Spec }
    else { $NotIncludedSpecs += [pscustomobject]@{ id = $Spec.id; worker = $Spec.worker; displayName = (Get-BKWorkerDisplayName -Cards $Cards -Id $Spec.worker); objective = $Spec.objective; workerName = (Get-BKChloeWorkerName $Spec.worker) } }
}
$NotIncludedWorkers = @($NotIncludedSpecs | ForEach-Object { $_.workerName })
if ($NotIncludedSpecs.Count -gt 0 -and $KeptSpecs.Count -eq 0) {
    $NamesText = Join-BKChloeNames -Names @($NotIncludedSpecs | ForEach-Object { $_.displayName }) -Lang "fr"
    $Verb = if ($NotIncludedSpecs.Count -gt 1) { "relève de $NamesText, qui ne font pas partie de vos Workers embauchés" } else { "relève de $NamesText, qui ne fait pas partie de vos Workers embauchés" }
    $Pron = if ($NotIncludedSpecs.Count -gt 1) { "Embauchez-les" } else { "Embauchez-le" }
    $Pron2 = if ($NotIncludedSpecs.Count -gt 1) { "leur" } else { "lui" }
    return [pscustomobject]@{
        Orchestrator       = "CHLOE"
        Request            = $Request
        SelectedWorkers    = @()
        NotIncludedWorkers = $NotIncludedWorkers
        HireOffer          = [pscustomobject]@{ workers = @($NotIncludedSpecs | ForEach-Object { $_.worker }); parts = @($NotIncludedSpecs | ForEach-Object { [pscustomobject]@{ worker = $_.worker; name = $_.displayName; objective = $_.objective } }) }
        Status             = "WORKER_NOT_INCLUDED"
        NextAction         = "HIRE_WORKER"
        Results            = @()
        PlanSource         = $PlanSource
        FinalSynthesis     = "Cette demande $Verb. $Pron (ou remplacez l'un de vos Workers) pour $Pron2 confier cette mission : aucune mission n'a été lancée et aucun crédit n'a été consommé."
    }
}
# Une sous-tache dont le prerequis n'est pas inclus ne l'attend pas : elle le sait (note dans sa consigne) et ne l'invente pas.
if ($NotIncludedSpecs.Count -gt 0) {
    $MissingIds = @($NotIncludedSpecs | ForEach-Object { $_.id })
    foreach ($Spec in $KeptSpecs) {
        $Lost = @(@($Spec.dependsOn) | Where-Object { $MissingIds -contains $_ })
        if ($Lost.Count -eq 0) { continue }
        $LostNames = Join-BKChloeNames -Names @($NotIncludedSpecs | Where-Object { $Lost -contains $_.id } | ForEach-Object { $_.displayName }) -Lang $Lang
        $Spec.dependsOn = @(@($Spec.dependsOn) | Where-Object { $MissingIds -notcontains $_ })
        $Spec.objective += $(if ($Lang -eq "fr") { "`n`nNote : le résultat de $LostNames n'est pas disponible dans cette mission (ce Worker ne fait pas partie du forfait du client). N'attends pas ce résultat et ne l'invente pas : pars d'hypothèses simples et dis clairement lesquelles." } else { "`n`nNote: the result of $LostNames is not available in this mission (that Worker is not part of the client's plan). Do not wait for it and do not invent it: start from simple assumptions and state them clearly." })
    }
}

# =================================================
# CREDITS : chaque Worker appele coute le niveau de la mission (Submit-Task.ps1). BK_MAX_WORKERS (pose par dashboard/server.py et
# dashboard/quota-check.py, via dashboard/chloe_scope.py) = credits utilisables MAINTENANT (mois, session et semaine, le plus bas) // cout du niveau :
# Chloe n'appelle jamais plus de Workers que le client n'a de credits pour en payer. Les sous-taches retenues sont les premieres dans l'ordre du graphe
# (jamais une sous-tache sans ses prerequis) ; les autres sont NOMMEES a la fin de la synthese. Absente ou invalide = pas de plafond.
# =================================================
$Budget = Get-BKChloeBudgetWorkers
$Split = Select-BKChloeBudgetTasks -Plan ([pscustomobject]@{ subtasks = $KeptSpecs }) -Budget $Budget
$KeptSpecs = @($Split.Kept)
$QuotaSkippedSpecs = @($Split.Skipped | ForEach-Object { [pscustomobject]@{ id = $_.id; worker = $_.worker; displayName = (Get-BKWorkerDisplayName -Cards $Cards -Id $_.worker); objective = $_.objective; workerName = (Get-BKChloeWorkerName $_.worker) } })
$QuotaSkippedWorkers = @($QuotaSkippedSpecs | ForEach-Object { $_.workerName })
$SelectedWorkers = @($KeptSpecs | ForEach-Object { Get-BKChloeWorkerName $_.worker })

# Mode projet (BK_PROJECTS=1 seulement) : une demande que le routeur juge trop grosse pour une mission est PROPOSEE comme projet (le client confirme,
# ou repond « juste rapidement » : BK_CHLOE_MODE=mission). Rien n'est execute, aucun credit consomme.
if ($ProjectsEnabled -and $PlanSource -eq "model" -and $Plan.mode -eq "project" -and $env:BK_CHLOE_MODE -ne "mission" -and -not $PlanOnly -and -not $EmitPlan) {
    return [pscustomobject]@{
        Orchestrator = "CHLOE"; Request = $Request; SelectedWorkers = $SelectedWorkers; NotIncludedWorkers = $NotIncludedWorkers
        Status = "SUGGEST_PROJECT"; NextAction = "CONFIRM_PROJECT"; Results = @(); PlanSource = $PlanSource
        SuggestProject = [pscustomobject]@{ why = [string]$Plan.why; workers = @($KeptSpecs | ForEach-Object { $_.worker }); tasks = @($KeptSpecs | ForEach-Object { [pscustomobject]@{ id = $_.id; worker = $_.worker; objective = $_.objective; dependsOn = @($_.dependsOn) } }) }
        FinalSynthesis = $L.SuggestProject
    }
}

if ($EmitPlan) {
    return [pscustomobject]@{
        Orchestrator = "CHLOE"; Request = $Request; Status = "PLAN_EMITTED"; NextAction = "AWAITING_VALIDATION"; PlanSource = $PlanSource
        SelectedWorkers = $SelectedWorkers; NotIncludedWorkers = $NotIncludedWorkers; QuotaSkippedWorkers = $QuotaSkippedWorkers
        Plan = [pscustomobject]@{
            schema = $Plan.schema; mode = $Plan.mode; source = $PlanSource; why = $Plan.why; consistencyCheck = $Plan.consistencyCheck
            subtasks = @($Plan.subtasks | ForEach-Object { [pscustomobject]@{ id = $_.id; worker = $_.worker; objective = $_.objective; why = $_.why; dependsOn = @($_.dependsOn); publicFacing = $_.publicFacing; included = ($null -eq $AllowedWorkers -or ($AllowedWorkers -contains [string]$_.worker)) } })
            unassignable = @($Plan.unassignable)
        }
        ChloeUsage = @($ChloeUsage)
    }
}

if ($PlanOnly) {
    return [pscustomobject]@{
        Orchestrator       = "CHLOE"
        Request            = $Request
        SelectedWorkers    = $SelectedWorkers
        NotIncludedWorkers = $NotIncludedWorkers
        QuotaSkippedWorkers = $QuotaSkippedWorkers
        Status             = "PLANNED"
        NextAction         = "AWAITING_VALIDATION"
        PlanSource         = $PlanSource
        Plan               = [pscustomobject]@{ mode = $Plan.mode; why = $Plan.why; subtasks = @($KeptSpecs | ForEach-Object { [pscustomobject]@{ id = $_.id; worker = $_.worker; objective = $_.objective; dependsOn = @($_.dependsOn) } }) }
    }
}

# =================================================
# EXECUTE : chaque sous-tache recoit sa propre consigne et son propre TaskId/ExecutionId uniques (la chaine anti-rejeu refuse un second
# enregistrement avec le meme TaskId), dans son propre processus, par le MEME chemin d'autorisation reel que n'importe quel appel direct.
# =================================================
$RunId = if ($env:BK_CHLOE_RUN_ID -match '^[A-Za-z0-9-]{8,48}$') { [string]$env:BK_CHLOE_RUN_ID } else { "RUN-" + [guid]::NewGuid().ToString("N").Substring(0, 16).ToUpperInvariant() }
$RunDir = New-BKChloeRunDir -Root $Root -ClientId $ClientId -RunId $RunId
Write-BKJsonAtomic -Path (Join-Path $RunDir "plan.json") -Object ([ordered]@{ runId = $RunId; source = $PlanSource; plan = $Plan; notIncluded = @($NotIncludedSpecs | ForEach-Object { $_.worker }); quotaSkipped = @($QuotaSkippedSpecs | ForEach-Object { $_.worker }) }) -Depth 8

$Inline = ($env:BK_CHLOE_EXECUTOR -eq "inline")
$TaskTable = [ordered]@{}
foreach ($Spec in $KeptSpecs) { $TaskTable[[string]$Spec.id] = New-BKChloeTask -Spec $Spec -Cards $Cards -RoutingConfig $RoutingConfig }
$Order = @(Get-BKTaskOrder -Tasks $KeptSpecs)
$Ctx = @{
    Root = $Root; Request = $Request; Lang = $Lang; ClientId = $ClientId; TenantId = $TenantId; ProjectId = $ProjectId; ExecutionId = $ExecutionId
    UserId = $UserId; SessionId = $SessionId; TokenId = $TokenId; Token = $Token; Mode = $Mode; Environment = $Environment
    RunId = $RunId; RunDir = $RunDir; Wrapper = (Join-Path $PSScriptRoot "Invoke-Chloe-WorkerCall.ps1"); Inline = $Inline
    Width = $(if ($Inline) { 1 } else { Get-BKChloeEnvInt -Name "BK_CHLOE_PARALLEL" -Default 2 -Min 1 -Max 4 })
    SlotTotal = (Get-BKChloeEnvInt -Name "BK_CHLOE_SLOTS_GLOBAL" -Default 3 -Min 1 -Max 8)
    SlotWaitSec = (Get-BKChloeEnvInt -Name "BK_CHLOE_SLOT_WAIT_SEC" -Default 300 -Min 5 -Max 540)
    MinLaunchSec = (Get-BKChloeEnvInt -Name "BK_CHLOE_MIN_LAUNCH_SEC" -Default 90 -Min 10 -Max 300)
    RunDeadline = $RunStart.AddSeconds((Get-BKChloeEnvInt -Name "BK_CHLOE_DEADLINE_SEC" -Default 535 -Min 30 -Max 585))
    Budget = $Budget; Tasks = $TaskTable; Order = $Order; Depths = (Get-BKTaskDepths -Tasks $KeptSpecs); LastProgress = ""
}
Invoke-BKChloeExecution -Ctx $Ctx

# =================================================
# REVIEW (coherence) : quand au moins deux Workers ont produit des contenus pour le meme public, un controle peu couteux compare leurs livrables.
# Facultatif et informatif (chloe/Chloe-Consistency.ps1). Jamais pour une mission Rapide, sauf BK_CHLOE_CONSISTENCY=1 ; BK_CHLOE_CONSISTENCY=0 le coupe.
# =================================================
$Consistency = $null
$WantConsistency = ($env:BK_CHLOE_CONSISTENCY -ne "0") -and ($Plan.consistencyCheck -or @($Ctx.Order | Where-Object { $Ctx.Tasks[$_].publicFacing -and $Ctx.Tasks[$_].status -eq "DONE" }).Count -ge 2) -and ($Level -ne "rapide" -or $env:BK_CHLOE_CONSISTENCY -eq "1")
if ($WantConsistency -and ($Ctx.RunDeadline - (Get-Date)).TotalSeconds -ge 45) {
    try { $Consistency = Invoke-BKChloeConsistency -Ctx $Ctx -Cards $Cards -Level $Level; if ($Consistency.Usage) { $ChloeUsage += , $Consistency.Usage } } catch { $Consistency = $null }
}

# =================================================
# COMBINE + DELIVER : une synthese qui dit QUI a fait QUOI (par Worker, avec ses fichiers et les actions a valider), ce qui a echoue ou n'a pas
# pu etre lance et quoi faire ensuite. Uniquement a partir des resultats qui ont passe la revue — jamais une synthese « succes » si les Workers
# delegues n'ont pas reellement reussi.
# =================================================
$ResetNote = ""
if ($env:BK_CHLOE_RESET_NOTE -match '^[\p{L}\p{N} .,:;()/@°-]{3,70}$') { $ResetNote = [string]$env:BK_CHLOE_RESET_NOTE }
$Cons = New-BKChloeConsolidation -Ctx $Ctx -Plan $Plan -NotIncluded $NotIncludedSpecs -QuotaSkipped $QuotaSkippedSpecs -ResetNote $ResetNote -Consistency $Consistency -L $L -Lang $Lang
$OverallStatus = $Cons.OverallStatus
$FinalSynthesis = $Cons.FinalSynthesis

$Results = @()
foreach ($Id in $Ctx.Order) {
    $T = $Ctx.Tasks[$Id]
    $LegacyStatus = if ($T.attempts -gt 0) { [string]$T.resultStatus } elseif ($T.reason -eq "DEPENDENCY_FAILED" -and $CollaborationMode -eq "CHAIN") { "SKIPPED_CHAIN_STOPPED" } else { "SKIPPED_" + [string]$T.reason }
    $Results += [pscustomobject]@{
        Worker = $T.workerName; TaskId = $T.taskId; Status = $LegacyStatus; Result = $T.result
        Step = $T.id; Objective = $T.objective; DependsOn = @($T.dependsOn); State = $T.status; Reason = $T.reason
        Attempts = [int]$T.attempts; DurationSec = [int]$T.durationSec; Degraded = [bool]$T.degraded
        Reviewed = [bool]$T.reviewed; ReviewNote = [string]$T.reviewNote
    }
    if ($T.error -and $T.status -ne "DONE") { $Results[-1] | Add-Member -NotePropertyName Error -NotePropertyValue ([string]$T.error) -Force }
}

# =================================================
# LEARN : depose un resume de la mission dans la memoire structuree (memory/data/) pour que les prochaines demandes similaires en beneficient —
# via le vrai moteur memoire (Memory-Access.ps1), pas un fichier ad-hoc.
# =================================================
$MemoryEngine = Join-Path $Root "memory/engine/Memory-Access.ps1"
$MemoryRuntimeDir = Join-Path $Root "memory/runtime"
$LearnStatus = "SKIPPED"

if (Test-Path -LiteralPath $MemoryEngine -PathType Leaf) {
    try {
        $CtxId = "CTX-CHLOE-LEARN-" + [guid]::NewGuid().ToString("N").Substring(0,10)
        $MemCtx = [ordered]@{
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
        $MemCtx | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $MemoryRuntimeDir "$CtxId.json") -Encoding UTF8

        $MemoryValue = "Demande: $Request`nWorkers: $($SelectedWorkers -join ', ')`nPlan: $PlanSource`nStatut: $OverallStatus`nSynthese: $(Limit-BKText -Text $FinalSynthesis -Max 3000)"
        $MemoryKey = "mission-" + $ExecutionId.Replace(":", "-")
        & $MemoryEngine -Action WRITE -ClientId $ClientId -ProjectId $ProjectId -WorkerId "CHLOE" -MemoryKey $MemoryKey -Value $MemoryValue | Out-Null
        $LearnStatus = "WRITTEN"
    }
    catch {
        $LearnStatus = "ERROR: " + $_.Exception.Message
    }
}

$CostUsd = 0.0
foreach ($U in @($ChloeUsage | Where-Object { $_ })) { $CostUsd += [double](Get-BKProp $U "estimated_cost_usd" 0) }

return [pscustomobject]@{
    Orchestrator      = "CHLOE"
    Request           = $Request
    CollaborationMode = $(if ($PlanSource -eq "model") { "PLAN" } else { $CollaborationMode })
    PlanSource        = $PlanSource
    RunId             = $RunId
    SelectedWorkers   = $SelectedWorkers
    NotIncludedWorkers = $NotIncludedWorkers
    QuotaSkippedWorkers = $QuotaSkippedWorkers
    HireOffer         = $(if ($NotIncludedSpecs.Count -gt 0) { [pscustomobject]@{ workers = @($NotIncludedSpecs | ForEach-Object { $_.worker }); parts = @($NotIncludedSpecs | ForEach-Object { [pscustomobject]@{ worker = $_.worker; name = $_.displayName; objective = $_.objective } }) } } else { $null })
    Status            = $OverallStatus
    NextAction        = if ($OverallStatus -eq "SUCCESS") { "REVIEW_RESULT" } else { "HUMAN_REVIEW_REQUIRED" }
    Results           = $Results
    Sections          = @($Cons.Sections)
    Overview          = $Cons.Overview
    Failures          = @($Cons.Failures)
    Deferred          = @($Cons.Deferred)
    ContinuePrompt    = $Cons.ContinuePrompt
    Consistency       = $(if ($Consistency -and $Consistency.Ok) { [pscustomobject]@{ issues = @($Consistency.Issues) } } else { $null })
    FinalSynthesis    = $FinalSynthesis
    ChloeCost         = [pscustomobject]@{ estimated_cost_usd = [Math]::Round($CostUsd, 6); calls = @($ChloeUsage | Where-Object { $_ }).Count }
    DurationSec       = [int]((Get-Date) - $RunStart).TotalSeconds
    LearnStatus       = $LearnStatus
}
