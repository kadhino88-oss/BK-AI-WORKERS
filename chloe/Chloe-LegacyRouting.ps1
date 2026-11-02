# =====================================================================
# CHLOE - ANCIEN ROUTAGE IA (repli du 2026-09-24), conserve tel quel pour BK_CHLOE_PLANNER=0 et pour la comparaison avec le routeur a modele
# (tests/chloe-delegation : jeu de demandes etiquetees). Deplace ici depuis chloe/Invoke-Chloe-Orchestration.ps1, sans changement de regles ;
# seul le modele est devenu un parametre (valeur par defaut identique a avant).
# Necessite core/ai/BK-Secret.ps1 (Test-BKSecret, Get-BKSecretValue) deja charge par l'appelant.
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
    # Plan de moteurs (2026-10-25, dashboard/provider_router.py) : ce routage est un appel DIRECT a Claude, avec la cle de la plateforme. Il n'est donc permis que
    # si Claude est le moteur prevu de cette mission, qu'il n'est pas ecarte (disjoncteur) et que le plafond de depense n'est pas atteint : un essai gratuit sur le
    # moteur local, une cle personnelle ou un plafond atteint ne declenchent AUCUN appel a Claude ici (Chloe retombe sur le routage par mots-cles). Sa depense
    # compte dans le registre du plafond. Sans plan : exactement le comportement d'avant.
    $EnginePlanActive = -not [string]::IsNullOrWhiteSpace($env:BK_ENGINE_PLAN)
    if ($EnginePlanActive) {
        try {
            . (Join-Path $Root "core/ai/adapters/Engine-Common.ps1")
            . (Join-Path $Root "core/ai/adapters/Mission-Cost.ps1")
            $EnginePlan = [string]$env:BK_ENGINE_PLAN | ConvertFrom-Json -ErrorAction Stop
            $FirstEngine = @($EnginePlan.chain)[0]
            if ($null -eq $FirstEngine -or [string]$FirstEngine.id -ne "anthropic") { return $null }
            if (-not (Test-BKEngineHealthy -Provider "anthropic")) { return $null }
            $RoutingBudget = Get-BKClaudeBudget
            if ($RoutingBudget.Configured -and $RoutingBudget.Reached) { return $null }
        } catch { return $null }
    }
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

        if ($EnginePlanActive) {
            # Cout reel de cet appel de routage, ajoute au registre de depense Claude (plafond du proprietaire).
            try {
                $RouteCost = New-BKMissionCost -Pricing (Get-BKPricing -Root $Root) -Model $BodyObj.model
                Add-BKCallCost -Cost $RouteCost -Response $Response
                $RouteFields = Get-BKCostUsageFields -Cost $RouteCost
                if ($RouteCost.Priced -and [double]$RouteFields.estimated_cost_usd -gt 0) { Add-BKEngineSpend -Chf ([double]$RouteFields.estimated_cost_chf) -Usd ([double]$RouteFields.estimated_cost_usd) }
            } catch { }
        }
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
