# =====================================================================
# BK-AI-WORKERS - Plafond de cout par mission (2026-10-12).
#
# Pourquoi : la boucle de l'adaptateur Anthropic (ANTHROPIC-ADAPTER.ps1) peut aller jusqu'a maxIterations appels et
# webMaxUses recherches web. L'etude de marche (docs/ETUDE-MARCHE-PRIX-2026-10.md, section 4.1) montre qu'une mission qui
# va au bout de sa boucle coute jusqu'a 4,35 CHF a l'Approfondi, dix fois une mission lourde. Chaque niveau de
# core/ai/LEVELS.json peut donc porter un plafond (maxCostChf) : ce fichier cumule le cout REEL de chaque appel et dit a la
# boucle de s'arreter proprement avant l'appel qui le depasserait.
#
# Regles :
#   - Les tarifs viennent de core/ai/AI-PRICING.json (la meme table que le resume des couts de dashboard/server.py) : aucun
#     prix n'est ecrit ici. Un modele sans tarif n'a ni cout affiche ni plafond applique (jamais devine).
#   - Cout d'un appel = jetons d'entree + ecriture du cache + lecture du cache + sortie (usage de la reponse) + recherches web
#     (usage.server_tool_use.web_search_requests x tarif par recherche). Converti en CHF avec le taux fixe du fichier de tarifs.
#   - Avant chaque appel SUIVANT (jamais avant le premier, qui est indispensable pour rendre quelque chose) :
#       1. cout deja engage >= plafond  -> on s'arrete ;
#       2. sinon on estime l'appel suivant de facon PRUDENTE et on s'arrete s'il fait depasser le plafond :
#          entree = le prompt du dernier appel + sa sortie + les nouveaux resultats d'outils (3 caracteres par jeton), facturee
#          plein tarif (aucun credit de cache) ; sortie = la plus grosse sortie vue dans la mission (au moins 2 000 jetons) ;
#          recherches web = celles du dernier appel. Ce qui ne peut pas etre connu a l'avance : les recherches web et la sortie
#          reelles de l'appel suivant (max_tokens reste a 64 000 : le couper rendrait une reponse tronquee en silence).
#   - Le suivi de cout ne doit JAMAIS faire echouer une mission : toute erreur ici rend un etat "incomplet" (cost_complete =
#     false) et la mission continue comme avant.
# =====================================================================

$Script:BKPricingCache = $null

function Get-BKPricing {
    # Table des tarifs (core/ai/AI-PRICING.json), lue une fois. $null si absente ou illisible.
    param([string]$Root)
    if ($null -ne $Script:BKPricingCache) { return $Script:BKPricingCache }
    try {
        $Parsed = Get-Content -LiteralPath (Join-Path $Root "core/ai/AI-PRICING.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Parsed -and $Parsed.models -and ([double]$Parsed.fxChfPerUsd) -gt 0) { $Script:BKPricingCache = $Parsed }
    } catch { }
    return $Script:BKPricingCache
}

function Get-BKModelPrice {
    # Meme resolution que price_for_model (dashboard/server.py) : identifiant exact, sans suffixe de date, puis plus long
    # prefixe. $null si le modele n'est pas dans la table.
    param($Pricing, [string]$Model)
    if ($null -eq $Pricing -or [string]::IsNullOrWhiteSpace($Model)) { return $null }
    $M = $Model.Trim().ToLowerInvariant()
    $Base = $M -replace '[-@]\d{6,8}$', ''
    $Entry = $null
    foreach ($Key in @($M, $Base)) {
        $Prop = $Pricing.models.PSObject.Properties[$Key]
        if ($Prop) { $Entry = $Prop.Value; break }
    }
    if ($null -eq $Entry) {
        foreach ($Name in @($Pricing.models.PSObject.Properties.Name | Sort-Object -Property Length -Descending)) {
            if ($Base.StartsWith($Name) -or $M.StartsWith($Name)) { $Entry = $Pricing.models.PSObject.Properties[$Name].Value; break }
        }
    }
    if ($null -eq $Entry -or $null -eq $Entry.input -or $null -eq $Entry.output) { return $null }

    $In = [double]$Entry.input
    $WriteMult = if ($Pricing.cacheDefaults -and $Pricing.cacheDefaults.writeMultiplier) { [double]$Pricing.cacheDefaults.writeMultiplier } else { 1.25 }
    $ReadMult  = if ($Pricing.cacheDefaults -and $Pricing.cacheDefaults.readMultiplier)  { [double]$Pricing.cacheDefaults.readMultiplier }  else { 0.1 }
    return [pscustomobject]@{
        Input          = $In
        Output         = [double]$Entry.output
        CacheWrite     = $(if ($null -ne $Entry.cacheWrite) { [double]$Entry.cacheWrite } else { $In * $WriteMult })
        CacheRead      = $(if ($null -ne $Entry.cacheRead)  { [double]$Entry.cacheRead }  else { $In * $ReadMult })
        LongAbove      = $(if ($Entry.longContextAbove) { [double]$Entry.longContextAbove } else { 0.0 })
        LongMultiplier = $(if ($Entry.longContextMultiplier) { [double]$Entry.longContextMultiplier } else { 1.0 })
        WebSearchUsd   = ([double]$Pricing.webSearchUsdPer1000) / 1000.0
        Fx             = [double]$Pricing.fxChfPerUsd
    }
}

function Get-BKCallCostUsd {
    # Cout en USD d'UN appel (ou d'une estimation d'appel) a partir de ses compteurs de jetons et de recherches web.
    param($Price, [double]$InputTokens = 0, [double]$OutputTokens = 0, [double]$CacheWriteTokens = 0, [double]$CacheReadTokens = 0, [double]$WebSearches = 0)
    $Mult = 1.0
    if ($Price.LongAbove -gt 0 -and ($InputTokens + $CacheWriteTokens + $CacheReadTokens) -gt $Price.LongAbove) { $Mult = $Price.LongMultiplier }
    $Tokens = ($InputTokens * $Price.Input) + ($CacheWriteTokens * $Price.CacheWrite) + ($CacheReadTokens * $Price.CacheRead) + ($OutputTokens * $Price.Output)
    return (($Tokens * $Mult) / 1000000.0) + ($WebSearches * $Price.WebSearchUsd)
}

function New-BKMissionCost {
    # Etat de cout d'une mission (table de hachage : mutable par reference). $CeilingChf = plafond en CHF ; $null, absent ou 0 =
    # pas de plafond.
    param($Pricing, [string]$Model, $CeilingChf = $null)
    $Price = $null
    try { $Price = Get-BKModelPrice -Pricing $Pricing -Model $Model } catch { }
    $Cap = $null
    try { if ($null -ne $CeilingChf -and ([double]$CeilingChf) -gt 0) { $Cap = [double]$CeilingChf } } catch { }
    return @{
        Price = $Price; Priced = ($null -ne $Price); CeilingChf = $Cap
        Calls = 0; InputTokens = [long]0; OutputTokens = [long]0; CacheWriteTokens = [long]0; CacheReadTokens = [long]0; WebSearches = 0
        Usd = 0.0; Complete = $true
        LastPromptTokens = [long]0; LastOutputTokens = [long]0; MaxOutputTokens = [long]0; LastWebSearches = 0
        Capped = $false; CapReason = ""
    }
}

function Add-BKCallCost {
    # A appeler apres CHAQUE reponse de l'API Messages : cumule les jetons et le cout de cet appel.
    param($Cost, $Response)
    try {
        $Cost.Calls++
        $U = if ($Response) { $Response.usage } else { $null }
        if ($null -eq $U) { $Cost.Complete = $false; return }
        $In  = [long]$U.input_tokens
        $Out = [long]$U.output_tokens
        $CW  = [long]$U.cache_creation_input_tokens
        $CR  = [long]$U.cache_read_input_tokens
        $Web = [int]$U.server_tool_use.web_search_requests
        $Cost.InputTokens += $In; $Cost.OutputTokens += $Out; $Cost.CacheWriteTokens += $CW; $Cost.CacheReadTokens += $CR; $Cost.WebSearches += $Web
        $Cost.LastPromptTokens = $In + $CW + $CR
        $Cost.LastOutputTokens = $Out
        $Cost.MaxOutputTokens = [Math]::Max([long]$Cost.MaxOutputTokens, $Out)
        $Cost.LastWebSearches = $Web
        if ($Cost.Priced) {
            $Cost.Usd += (Get-BKCallCostUsd -Price $Cost.Price -InputTokens $In -OutputTokens $Out -CacheWriteTokens $CW -CacheReadTokens $CR -WebSearches $Web)
        }
    } catch { $Cost.Complete = $false }
}

function Test-BKCostGate {
    # A appeler juste AVANT chaque appel suivant. Stop = $true : ne pas lancer l'appel. $NewChars = taille (en caracteres) de
    # ce qui s'ajoute au prompt depuis le dernier appel (resultats d'outils).
    param($Cost, [double]$NewChars = 0)
    $Gate = [pscustomobject]@{ Stop = $false; Reason = ""; ProjectedUsd = [double]0 }
    try {
        if (-not $Cost.Priced -or -not $Cost.CeilingChf) { return $Gate }
        $CapUsd = $Cost.CeilingChf / $Cost.Price.Fx
        $Gate.ProjectedUsd = [double]$Cost.Usd
        if ($Cost.Usd -ge $CapUsd) { $Gate.Stop = $true; $Gate.Reason = "ceiling-reached"; return $Gate }
        $EstPrompt = [double]$Cost.LastPromptTokens + [double]$Cost.LastOutputTokens + [Math]::Ceiling($NewChars / 3.0)
        $EstOutput = [Math]::Max(2000.0, [double]$Cost.MaxOutputTokens)
        $Est = Get-BKCallCostUsd -Price $Cost.Price -InputTokens $EstPrompt -OutputTokens $EstOutput -WebSearches ([double]$Cost.LastWebSearches)
        $Gate.ProjectedUsd = [double]$Cost.Usd + $Est
        if ($Gate.ProjectedUsd -gt $CapUsd) { $Gate.Stop = $true; $Gate.Reason = "next-call-would-exceed" }
    } catch { }
    return $Gate
}

function Get-BKCostUsageFields {
    # Champs a fusionner dans usage du resultat de la mission. input_tokens / output_tokens sont CUMULES sur tous les appels de
    # la boucle (avant le 2026-10-12, seul le dernier appel etait releve) ; le resume des couts du dashboard prefere
    # estimated_cost_usd quand il est present.
    param($Cost)
    $Priced = [bool]$Cost.Priced
    return [ordered]@{
        input_tokens = [long]$Cost.InputTokens
        output_tokens = [long]$Cost.OutputTokens
        cache_creation_input_tokens = [long]$Cost.CacheWriteTokens
        cache_read_input_tokens = [long]$Cost.CacheReadTokens
        web_search_requests = [int]$Cost.WebSearches
        api_calls = [int]$Cost.Calls
        estimated_cost_usd = $(if ($Priced) { [Math]::Round([double]$Cost.Usd, 6) } else { $null })
        estimated_cost_chf = $(if ($Priced) { [Math]::Round([double]$Cost.Usd * [double]$Cost.Price.Fx, 4) } else { $null })
        fx_chf_per_usd = $(if ($Priced) { [double]$Cost.Price.Fx } else { $null })
        cost_ceiling_chf = $Cost.CeilingChf
        cost_priced = $Priced
        cost_complete = [bool]$Cost.Complete
        cost_capped = [bool]$Cost.Capped
        cost_cap_reason = [string]$Cost.CapReason
    }
}

function Get-BKCostCapNote {
    # Note en francais ajoutee a la meilleure reponse obtenue quand la mission est arretee au plafond : factuelle (actions et
    # connecteurs connus du code, jamais du texte ecrit par le modele), sans montant (le plafond est un cout interne).
    param($PendingActions = @(), $UnusedReads = @(), [int]$FileCount = 0)
    $Todo = @()
    foreach ($A in @($PendingActions)) { if ($A) { $Todo += "à confirmer par vous depuis votre tableau de bord (rien n'est parti) : $($A.connectorId) — $($A.operation)" } }
    foreach ($R in @($UnusedReads)) { if ($R) { $Todo += "consultation déjà faite mais pas encore exploitée : $($R.connectorId) — $($R.operation)" } }
    $Todo += "la suite de la demande, qui n'a pas été traitée"
    $Lines = @()
    $Lines += "Mission arrêtée au plafond de coût : elle a atteint la limite de dépense prévue pour une mission de ce niveau, donc je n'ai lancé aucune étape de plus. Ce qui précède est ce qui était fait à ce stade."
    $Lines += ""
    $Lines += "Ce qu'il reste à faire :"
    foreach ($T in $Todo) { $Lines += "- $T" }
    if ($FileCount -gt 0) {
        $Lines += ""
        $Lines += "Les fichiers joints sont dans l'état où ils étaient à l'arrêt : ils peuvent être incomplets, à vérifier avant tout usage."
    }
    $Lines += ""
    $Lines += "Écrivez « continue » pour reprendre à partir de ce travail (nouvelle mission), ou découpez la demande en plusieurs missions plus courtes."
    return ($Lines -join "`n")
}
