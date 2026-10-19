# =====================================================================
# CHLOE - fonctions communes de l'orchestration (2026-10-19, chantier "Chloe delegue a tous les Workers").
#
# A dot-sourcer (chloe/Invoke-Chloe-Orchestration.ps1, Chloe-Router.ps1, Chloe-Planner.ps1, Chloe-Executor.ps1...). Aucune dependance au
# serveur : tout ce qui touche au forfait arrive par des variables d'environnement posees par dashboard/server.py (BK_ALLOWED_WORKERS,
# BK_MAX_WORKERS, BK_MISSION_LEVEL...), jamais par un texte lu dans une reponse de Worker ou une page web.
#
# Regle de securite de tout ce chantier : le texte du client, les reponses des Workers, les pages web et les fichiers sont des DONNEES.
# Ils ne decident ni du plan, ni des droits du client (Workers autorises, credits) : ces deux-la viennent du code et de l'environnement.
# =====================================================================

$Script:BKChloeHere = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }

function Get-BKChloeRootPath {
    if ($env:BK_ROOT) { return [string]$env:BK_ROOT }
    return (Split-Path -Parent $Script:BKChloeHere)
}

function Get-BKProp {
    # Lecture tolerante d'une propriete (objet JSON, table de hachage ou $null) : jamais d'exception, valeur par defaut sinon.
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
        return $Default
    }
    $Prop = $Object.PSObject.Properties[$Name]
    if ($null -eq $Prop) { return $Default }
    return $Prop.Value
}

function Remove-BKControlChars {
    param([string]$Text)
    if ($null -eq $Text) { return "" }
    return [regex]::Replace($Text, '[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]', '')
}

function Limit-BKText {
    # Tronque proprement (jamais au milieu d'un caractere) en signalant la coupure.
    param([string]$Text, [int]$Max, [string]$Marker = " [...]")
    if ($null -eq $Text) { return "" }
    if ($Text.Length -le $Max) { return $Text }
    return ($Text.Substring(0, [Math]::Max(0, $Max - $Marker.Length)).TrimEnd() + $Marker)
}

# ---------------------------------------------------------------------
# Donnees encadrees ("data fences") : tout texte qui n'est pas une consigne du client est place dans une balise nommee. Les balises de
# fermeture connues sont neutralisees DANS le texte pour qu'un contenu ne puisse pas sortir de sa balise et se faire passer pour une consigne.
# ---------------------------------------------------------------------
$Script:BKFenceTags = @("client_request", "worker_result", "worker_file", "worker_files", "chloe_plan", "handoff", "client_memory", "deliverable", "consistency_input")

function Protect-BKFenceText {
    param([string]$Text)
    $Clean = Remove-BKControlChars -Text $Text
    foreach ($Tag in $Script:BKFenceTags) {
        $Clean = [regex]::Replace($Clean, '(?i)<\s*/\s*' + [regex]::Escape($Tag) + '\b', ('<\/' + $Tag))
        $Clean = [regex]::Replace($Clean, '(?i)<\s*' + [regex]::Escape($Tag) + '\b', ('<\' + $Tag))
    }
    return $Clean
}

function New-BKDataFence {
    param([Parameter(Mandatory=$true)][string]$Tag, [string]$Text, [System.Collections.IDictionary]$Attrs = @{}, [int]$Max = 8000)
    $A = ""
    foreach ($K in @($Attrs.Keys)) {
        $V = ([string]$Attrs[$K]) -replace '[^A-Za-z0-9_.:-]', '_'
        $A += " $K=`"$V`""
    }
    $Body = Protect-BKFenceText -Text (Limit-BKText -Text $Text -Max $Max)
    return "<$Tag$A>`n$Body`n</$Tag>"
}

function Test-BKChloeSecretLike {
    # Meme detecteur que la memoire du client (Client-Memory.ps1 : Test-BKSecretLike), recopie ici pour ne pas en dependre.
    param([string]$Text)
    return ([string]$Text -match 'sk-[A-Za-z0-9_-]{16,}|AIza[0-9A-Za-z_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|xox[abp]-[0-9A-Za-z-]{10,}|ghp_[A-Za-z0-9]{20,}|(?i)(password|mot de passe|mdp|api[ _-]?key|cl[eé] api|secret|token|iban)\s*[:=]\s*\S{6,}')
}

# ---------------------------------------------------------------------
# Noms, langue, libelles
# ---------------------------------------------------------------------
function Format-BKWorkerName {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $Name }
    return $Name.Substring(0, 1).ToUpperInvariant() + $Name.Substring(1).ToLowerInvariant()
}

function Get-BKChloeReplyLang {
    # Langue des textes que Chloe ecrit elle-meme (libelles, resume) : BK_REPLY_LANG (pose par le serveur, detection par mots courants) ;
    # sans indication, le francais (langue de la plateforme).
    param([string]$Request = "")
    $L = ([string]$env:BK_REPLY_LANG).Trim()
    if ($L -match '^(?i)french$|^fr') { return "fr" }
    if ($L -match '^(?i)english$|^en') { return "en" }
    if ($L -match '^[A-Za-z]{2,20}$') { return "other:" + $L }
    if ($Request -match '(?i)\b(the|and|please|with|for|my|our|want|need)\b' -and $Request -notmatch '(?i)\b(le|la|les|des|pour|avec|mon|ma|nos|veux|besoin)\b') { return "en" }
    return "fr"
}

$Script:BKChloeLabelsFr = @{
    Intro            = "Chloé a réparti votre demande entre {0} Workers : {1}."
    Asked            = "Demandé"
    Done             = "Terminé"
    Failed           = "Échec"
    Blocked          = "Non lancé"
    Deferred         = "Reporté"
    TimedOut         = "Interrompu (délai)"
    Files            = "Fichiers produits"
    ToValidate       = "À valider de votre part"
    ToValidateItem   = "{0} a préparé une action ({1} : {2}). Elle n'est PAS partie : confirmez-la dans votre tableau de bord."
    NotDone          = "Non réalisé"
    NotIncluded      = "Non inclus dans votre forfait, donc non traités : {0}."
    HireOffer        = "Vous pouvez embaucher {0} (ou remplacer l'un de vos Workers) pour lui confier cette partie : dites-le-moi et je la relance."
    QuotaNote        = "Faute de crédits suffisants ce mois-ci pour tous les Workers, non traités : {0}. Relancez-les séparément, avec un niveau plus rapide ou au forfait supérieur."
    QuotaWindowNote  = "Faute de crédits disponibles maintenant pour tous les Workers, non traités : {0}. Vos crédits se renouvellent {1} : relancez-les à ce moment-là, avec un niveau plus rapide, ou passez au forfait supérieur."
    TimeNote         = "Le temps imparti à une mission est écoulé : non traités : {0}. Relancez cette partie dans un nouveau message, ou lancez-la comme projet."
    FailedNote       = "{0} n'a pas abouti ({1}). Les autres Workers ont terminé. Vous pouvez relancer cette partie seule, en précisant votre demande."
    DependencyNote   = "{0} n'a pas été lancé : il avait besoin du résultat de {1}, qui n'a pas abouti."
    Consistency      = "À harmoniser entre les livrables"
    NoResult         = "Aucun résultat vérifié à livrer pour cette demande."
    Continue         = "Pour la suite, écrivez par exemple : « {0} »."
    SuggestProject   = "Cette demande demande plusieurs étapes et plusieurs Workers : je vous propose de la lancer comme projet (plan validé avant tout crédit dépensé), ou de répondre juste rapidement."
    WorkerLine       = "{0} — {1}"
}
$Script:BKChloeLabelsEn = @{
    Intro            = "Chloé split your request between {0} Workers: {1}."
    Asked            = "Asked"
    Done             = "Done"
    Failed           = "Failed"
    Blocked          = "Not started"
    Deferred         = "Postponed"
    TimedOut         = "Stopped (time limit)"
    Files            = "Files produced"
    ToValidate       = "Needs your approval"
    ToValidateItem   = "{0} prepared an action ({1}: {2}). It has NOT been sent: confirm it in your dashboard."
    NotDone          = "Not done"
    NotIncluded      = "Not included in your plan, so not handled: {0}."
    HireOffer        = "You can hire {0} (or swap one of your Workers) to give them this part: tell me and I will start it."
    QuotaNote        = "Not enough credits left this month for every Worker, not handled: {0}. Run them separately, at a faster level, or on a higher plan."
    QuotaWindowNote  = "Not enough credits available right now for every Worker, not handled: {0}. Your credits renew {1}: run them again then, at a faster level, or move to the next plan."
    TimeNote         = "The time allowed for one mission ran out: not handled: {0}. Send that part in a new message, or start it as a project."
    FailedNote       = "{0} did not complete ({1}). The other Workers finished. You can run that part again on its own, with a more precise request."
    DependencyNote   = "{0} was not started: it needed the result of {1}, which did not complete."
    Consistency      = "To align across the deliverables"
    NoResult         = "No verified result to deliver for this request."
    Continue         = "To continue, write for example: `"{0}`"."
    SuggestProject   = "This request needs several steps and several Workers: I suggest running it as a project (plan approved before any credit is spent), or just answering quickly."
    WorkerLine       = "{0} — {1}"
}

function Get-BKChloeLabels {
    param([string]$Lang = "fr")
    if ($Lang -eq "fr") { return $Script:BKChloeLabelsFr }
    return $Script:BKChloeLabelsEn
}

# ---------------------------------------------------------------------
# Droits du client : BK_ALLOWED_WORKERS (pose par le serveur, source UNIQUE) ; null = tous les Workers, "-" = aucun.
# ---------------------------------------------------------------------
function Get-BKChloeAllowedWorkers {
    $Raw = [string]$env:BK_ALLOWED_WORKERS
    if ([string]::IsNullOrWhiteSpace($Raw)) { return $null }
    # La virgule garde un tableau VIDE (« - » ou valeur illisible = aucun Worker) : sans elle PowerShell renverrait $null, c'est-a-dire « tous ».
    return , @($Raw.ToLowerInvariant().Split(",") | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[a-z]{2,20}$' })
}

function Get-BKChloeBudgetWorkers {
    # Nombre de Workers que les credits (et les fenetres d'usage) permettent de payer pour cette mission : BK_MAX_WORKERS, pose par le serveur
    # (dashboard/chloe_scope.py : credits autorises // cout du niveau). $null = pas de plafond (proprietaire, essai public).
    $N = 0
    if ([int]::TryParse([string]$env:BK_MAX_WORKERS, [ref]$N) -and $N -ge 1) { return $N }
    return $null
}

function Get-BKChloeRosterIds {
    # Identifiants des Workers que Chloe peut nommer : ceux de worker-routing.json, moins les exclus (Atlas : trading personnel du proprietaire).
    param($RoutingConfig)
    $Excluded = @($RoutingConfig.excluded_from_routing)
    return @($RoutingConfig.workers.PSObject.Properties.Name | Where-Object { $Excluded -notcontains $_ })
}

function Get-BKChloeCards {
    # Cartes des Workers (core/projects/WORKER-CARDS.json, genere par chloe/Build-WorkerCards.ps1). Sans fichier : cartes minimales construites
    # a la volee (role de l'identite + mots-cles de routage), pour que le routage fonctionne meme avant la generation.
    param([string]$Root, $RoutingConfig)
    $Cards = @{}
    $Path = Join-Path $Root "core/projects/WORKER-CARDS.json"
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $Doc = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
            $List = if ($Doc -is [System.Array]) { $Doc } else { Get-BKProp $Doc "cards" @() }
            foreach ($C in @($List)) { if ($C -and $C.id) { $Cards[[string]$C.id] = $C } }
        } catch { }
    }
    foreach ($Id in (Get-BKChloeRosterIds -RoutingConfig $RoutingConfig)) {
        if ($Cards.ContainsKey($Id)) { continue }
        $Name = Format-BKWorkerName $Id
        $Role = ""
        $IdPath = Join-Path $Root ("workers/" + $Id + "/identity/identity.json")
        if (Test-Path -LiteralPath $IdPath -PathType Leaf) {
            try { $Ident = Get-Content -LiteralPath $IdPath -Raw -Encoding UTF8 | ConvertFrom-Json; if ($Ident.name) { $Name = [string]$Ident.name }; if ($Ident.role) { $Role = [string]$Ident.role } } catch { }
        }
        $Cards[$Id] = [pscustomobject]@{
            id = $Id; name = $Name; role = $Role; can = @(); notFor = @(); connectors = @(); recipes = @()
            keywords = @($RoutingConfig.workers.PSObject.Properties[$Id].Value.primary); typicalStepCredits = @(4, 12)
        }
    }
    return $Cards
}

function Get-BKWorkerDisplayName {
    param($Cards, [string]$Id)
    if ($Cards -and $Cards.ContainsKey($Id) -and $Cards[$Id].name) { return [string]$Cards[$Id].name }
    return (Format-BKWorkerName $Id)
}

# ---------------------------------------------------------------------
# Graphe de sous-taches (sans cycle) : ordre topologique stable, vagues, longueur du chemin critique
# ---------------------------------------------------------------------
function Get-BKTaskOrder {
    # Ordre topologique STABLE (a egalite : l'ordre du plan) de taches {id, dependsOn}. $null s'il y a un cycle. Les appelants l'enveloppent dans @().
    param([array]$Tasks)
    $Ids = @($Tasks | ForEach-Object { [string]$_.id })
    $Remaining = [System.Collections.ArrayList]@($Ids)
    $Done = @{}
    $Order = @()
    $ById = @{}
    foreach ($T in $Tasks) { $ById[[string]$T.id] = $T }
    while ($Remaining.Count -gt 0) {
        $Picked = $null
        foreach ($Id in $Remaining) {
            $Deps = @($ById[$Id].dependsOn | Where-Object { $Ids -contains [string]$_ })
            if (@($Deps | Where-Object { -not $Done.ContainsKey([string]$_) }).Count -eq 0) { $Picked = $Id; break }
        }
        if ($null -eq $Picked) { return $null }
        $Order += $Picked
        $Done[$Picked] = $true
        [void]$Remaining.Remove($Picked)
    }
    return $Order
}

function Get-BKTaskDepths {
    # Pour chaque tache : nombre de taches du plus long chemin qui part d'elle vers l'aval (sert a lancer d'abord le chemin critique).
    param([array]$Tasks)
    $Children = @{}
    foreach ($T in $Tasks) { $Children[[string]$T.id] = @() }
    foreach ($T in $Tasks) { foreach ($D in @($T.dependsOn)) { if ($Children.ContainsKey([string]$D)) { $Children[[string]$D] += [string]$T.id } } }
    $Memo = @{}
    function _Depth([string]$Id, $Stack) {
        if ($Memo.ContainsKey($Id)) { return $Memo[$Id] }
        if ($Stack -contains $Id) { return 0 }
        $Best = 0
        foreach ($C in $Children[$Id]) { $Best = [Math]::Max($Best, (_Depth $C ($Stack + $Id))) }
        $Memo[$Id] = $Best + 1
        return $Memo[$Id]
    }
    $Out = @{}
    foreach ($T in $Tasks) { $Out[[string]$T.id] = _Depth ([string]$T.id) @() }
    return $Out
}

# ---------------------------------------------------------------------
# Plan de mission (BK-CHLOE-ROUTE-PLAN-V1) : schema DUR et validation par le code. Rien de ce qui sort du modele n'est cru tel quel.
# ---------------------------------------------------------------------
$Script:BKChloeMaxTasks = 17          # un Worker au plus par sous-tache : la limite est le nombre de Workers, pas un plafond arbitraire
$Script:BKChloeRouteModes = @("direct_reply", "mission", "project")

function Test-BKChloeRoutePlan {
    # Valide et NORMALISE un plan brut (objet JSON). Renvoie @{ Ok; Errors = [FR]; Plan }. Les champs inconnus sont ignores (jamais recopies).
    param($Raw, [string[]]$KnownWorkers, [int]$MaxTasks = $Script:BKChloeMaxTasks)
    $Errors = @()
    if ($null -eq $Raw -or $Raw -is [string] -or $Raw -is [System.Array]) {
        return @{ Ok = $false; Errors = @("Le plan doit etre un objet JSON avec les champs mode et subtasks."); Plan = $null }
    }
    $Mode = ([string](Get-BKProp $Raw "mode" "")).Trim().ToLowerInvariant()
    $RawTasks = @(Get-BKProp $Raw "subtasks" @() | Where-Object { $null -ne $_ })
    if ([string]::IsNullOrWhiteSpace($Mode)) { $Mode = if ($RawTasks.Count -gt 0) { "mission" } else { "" } }
    if ($Script:BKChloeRouteModes -notcontains $Mode) { $Errors += "mode doit etre direct_reply, mission ou project." }

    $Direct = [string](Get-BKProp $Raw "directReply" "")
    if ($null -ne (Get-BKProp $Raw "direct_reply" $null) -and [string]::IsNullOrWhiteSpace($Direct)) { $Direct = [string](Get-BKProp $Raw "direct_reply" "") }
    $Direct = (Remove-BKControlChars -Text $Direct).Trim()

    $Tasks = @()
    $SeenIds = @{}
    $SeenWorkers = @{}
    if ($Mode -eq "direct_reply") {
        if ([string]::IsNullOrWhiteSpace($Direct)) { $Errors += "mode direct_reply sans texte de reponse (directReply)." }
        if ($RawTasks.Count -gt 0) { $Errors += "mode direct_reply : subtasks doit etre vide." }
    }
    elseif ($Mode -in @("mission", "project")) {
        if ($RawTasks.Count -eq 0) { $Errors += "mode $Mode : au moins une sous-tache (subtasks) est requise." }
        if ($RawTasks.Count -gt $MaxTasks) { $Errors += "Au plus $MaxTasks sous-taches (une par Worker) : regroupez-les." }
        $Index = 0
        foreach ($T in ($RawTasks | Select-Object -First $MaxTasks)) {
            $Index++
            $Id = ([string](Get-BKProp $T "id" "")).Trim().ToUpperInvariant()
            if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "T$Index" }
            if ($Id -notmatch '^T[0-9]{1,2}$') { $Errors += "Identifiant de sous-tache invalide : $Id (attendu : T1, T2...)."; continue }
            if ($SeenIds.ContainsKey($Id)) { $Errors += "Identifiant de sous-tache en double : $Id."; continue }
            $Worker = ([string](Get-BKProp $T "worker" "")).Trim().ToLowerInvariant()
            if ($Worker -notmatch '^[a-z]{2,20}$' -or ($KnownWorkers -notcontains $Worker)) {
                $Errors += "Sous-tache ${Id} : Worker inconnu ou invalide (" + (Limit-BKText -Text $Worker -Max 24) + "). Choisissez un identifiant de la liste."
                continue
            }
            if ($SeenWorkers.ContainsKey($Worker)) { $Errors += "Sous-tache ${Id} : le Worker $Worker a deja une sous-tache ($($SeenWorkers[$Worker])) ; regroupez ses objectifs en une seule."; continue }
            $Objective = (Remove-BKControlChars -Text ([string](Get-BKProp $T "objective" ""))).Trim()
            if ($Objective.Length -lt 8) { $Errors += "Sous-tache ${Id} : objectif manquant ou trop court."; continue }
            if ($Objective.Length -gt 2000) { $Objective = Limit-BKText -Text $Objective -Max 2000 }
            $Deps = @(@(Get-BKProp $T "dependsOn" @()) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ })
            $Deliv = @(@(Get-BKProp $T "deliverables" @()) | ForEach-Object { Limit-BKText -Text (Remove-BKControlChars -Text ([string]$_)).Trim() -Max 120 } | Where-Object { $_ } | Select-Object -First 6)
            $Pub = Get-BKProp $T "publicFacing" $false
            $SeenIds[$Id] = $true
            $SeenWorkers[$Worker] = $Id
            $Tasks += [ordered]@{
                id = $Id; worker = $Worker; objective = $Objective
                why = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $T "why" ""))).Trim() -Max 300)
                dependsOn = $Deps; deliverables = $Deliv; publicFacing = ([bool]($Pub -eq $true -or [string]$Pub -eq "true"))
            }
        }
        foreach ($T in $Tasks) {
            foreach ($D in $T.dependsOn) {
                if ($D -eq $T.id) { $Errors += "Sous-tache $($T.id) : depend d'elle-meme." }
                elseif (-not $SeenIds.ContainsKey($D)) { $Errors += "Sous-tache $($T.id) : depend de $D qui n'existe pas." }
            }
        }
        if ($Errors.Count -eq 0 -and $Tasks.Count -gt 0 -and $null -eq (Get-BKTaskOrder -Tasks $Tasks)) { $Errors += "Les dependances forment un cycle : un plan doit etre un graphe sans boucle." }
    }

    $Unassignable = @()
    foreach ($U in @(Get-BKProp $Raw "unassignable" @() | Select-Object -First 10)) {
        $Cap = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $U "capability" ""))).Trim() -Max 200)
        if ($Cap) { $Unassignable += [ordered]@{ capability = $Cap; bestWorker = ([string](Get-BKProp $U "bestWorker" "")).Trim().ToLowerInvariant(); reason = (Limit-BKText -Text ([string](Get-BKProp $U "reason" "")) -Max 300) } }
    }
    if ($Errors.Count -gt 0) { return @{ Ok = $false; Errors = $Errors; Plan = $null } }
    $Plan = [ordered]@{
        schema = "BK-CHLOE-ROUTE-PLAN-V1"
        mode = $Mode
        language = (Limit-BKText -Text ([string](Get-BKProp $Raw "language" "")) -Max 20)
        why = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $Raw "why" ""))).Trim() -Max 400)
        directReply = $(if ($Mode -eq "direct_reply") { Limit-BKText -Text $Direct -Max 1500 } else { $null })
        consistencyCheck = [bool]((Get-BKProp $Raw "consistencyCheck" $false) -eq $true)
        subtasks = @($Tasks)
        unassignable = @($Unassignable)
    }
    return @{ Ok = $true; Errors = @(); Plan = $Plan }
}

# ---------------------------------------------------------------------
# Appel du modele (routeur, planificateur, controle de coherence) : un seul point d'appel, cout comptabilise, jamais d'exception
# ---------------------------------------------------------------------
function Get-BKChloeApiKey {
    try {
        if (-not (Get-Command Test-BKSecret -ErrorAction SilentlyContinue)) { . (Join-Path (Get-BKChloeRootPath) "core/ai/BK-Secret.ps1") }
        if (-not (Test-BKSecret -Name "anthropic")) { return $null }
        $K = Get-BKSecretValue -Name "anthropic"
        if ([string]::IsNullOrWhiteSpace($K)) { return $null }
        return $K
    } catch { return $null }
}

function Import-BKChloeCostHelpers {
    if (Get-Command New-BKMissionCost -ErrorAction SilentlyContinue) { return $true }
    $P = Join-Path (Get-BKChloeRootPath) "core/ai/adapters/Mission-Cost.ps1"
    if (Test-Path -LiteralPath $P -PathType Leaf) { try { . $P; return $true } catch { } }
    return $false
}

function Invoke-BKChloeLlm {
    # Un appel Messages (sans outil serveur). $Tool = definition d'outil client dont l'entree EST le resultat attendu (schema dur) ; la reponse
    # est lue dans le bloc tool_use, a defaut dans le texte (JSON). Renvoie @{ Ok; Input; Text; Usage; Model; Error } ; Ok = false si l'API est
    # indisponible, sans cle ou sans reponse exploitable : l'appelant bascule alors sur son repli, jamais d'exception ici.
    param(
        [Parameter(Mandatory=$true)][string]$Model,
        [Parameter(Mandatory=$true)][string]$System,
        [Parameter(Mandatory=$true)][string]$User,
        $Tool = $null,
        [int]$MaxTokens = 1500,
        [int]$TimeoutSec = 25,
        [int]$Retries = 1,
        [string]$Effort = ""
    )
    $Key = Get-BKChloeApiKey
    if ($null -eq $Key) { return @{ Ok = $false; Error = "NO_KEY"; Input = $null; Text = ""; Usage = $null; Model = $Model } }
    $Root = Get-BKChloeRootPath
    $Cost = $null
    if (Import-BKChloeCostHelpers) { try { $Cost = New-BKMissionCost -Pricing (Get-BKPricing -Root $Root) -Model $Model } catch { $Cost = $null } }
    $Body = [ordered]@{
        model = $Model; max_tokens = $MaxTokens
        system = $System
        messages = @(@{ role = "user"; content = $User })
    }
    if ($Tool) { $Body["tools"] = @($Tool) }
    if ($Effort -and $Model -notlike "claude-haiku-4*") { $Body["output_config"] = @{ effort = $Effort } }
    $Headers = @{ "x-api-key" = $Key; "anthropic-version" = "2023-06-01" }
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 12))
    $Response = $null
    $LastError = ""
    for ($Try = 0; $Try -le $Retries; $Try++) {
        try {
            $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $Headers -ContentType "application/json; charset=utf-8" -Body $Bytes -TimeoutSec $TimeoutSec
            break
        } catch {
            $Code = 0
            try { $Code = [int]$_.Exception.Response.StatusCode } catch { }
            $LastError = "HTTP $Code " + (Limit-BKText -Text ([string]$_.Exception.Message) -Max 160)
            if ($Code -ne 0 -and $Code -ne 429 -and $Code -lt 500) { break }      # 4xx autre que 429 : inutile de reessayer
            if ($Try -lt $Retries) { Start-Sleep -Seconds (2 + 3 * $Try) }
        }
    }
    $Key = $null
    if ($null -eq $Response) { return @{ Ok = $false; Error = $LastError; Input = $null; Text = ""; Usage = $null; Model = $Model } }
    $UsageFields = $null
    if ($Cost) { try { Add-BKCallCost -Cost $Cost -Response $Response; $UsageFields = Get-BKCostUsageFields -Cost $Cost } catch { } }
    $ToolInput = $null
    $Text = ""
    foreach ($Block in @($Response.content)) {
        if ($null -eq $Block) { continue }
        if ($Block.type -eq "tool_use" -and $Tool -and $Block.name -eq $Tool.name -and $null -eq $ToolInput) { $ToolInput = $Block.input }
        elseif ($Block.type -eq "text") { $Text += [string]$Block.text }
    }
    if ($null -eq $ToolInput -and $Text) {
        $Raw = $Text.Trim() -replace '^```json\s*', '' -replace '^```\s*', '' -replace '```\s*$', ''
        $Start = $Raw.IndexOf("{"); $End = $Raw.LastIndexOf("}")
        if ($Start -ge 0 -and $End -gt $Start) {
            try { $ToolInput = $Raw.Substring($Start, $End - $Start + 1) | ConvertFrom-Json -ErrorAction Stop } catch { $ToolInput = $null }
        }
    }
    return @{ Ok = ($null -ne $ToolInput); Error = $(if ($null -eq $ToolInput) { "NO_STRUCTURED_OUTPUT" } else { "" }); Input = $ToolInput; Text = $Text; Usage = $UsageFields; Model = $Model }
}

# ---------------------------------------------------------------------
# Fichiers : ecriture atomique d'un JSON (fichier temporaire puis remplacement)
# ---------------------------------------------------------------------
function Write-BKJsonAtomic {
    param([string]$Path, $Object, [int]$Depth = 12)
    $Dir = Split-Path -Parent $Path
    if ($Dir -and -not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $Tmp = $Path + "." + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".tmp"
    [System.IO.File]::WriteAllText($Tmp, ($Object | ConvertTo-Json -Depth $Depth), [System.Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $Tmp -Destination $Path -Force
}

function Read-BKJsonFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# ---------------------------------------------------------------------
# Capacite du serveur (2 vCPU / 3,8 Go) : places de lancement partagees entre TOUTES les missions de Chloe en cours, par verrous de fichier.
# Un verrou est libere par le systeme si le processus meurt : jamais de place perdue.
# ---------------------------------------------------------------------
function Get-BKMemAvailableMb {
    try {
        if (Test-Path -LiteralPath "/proc/meminfo") {
            $Line = Get-Content -LiteralPath "/proc/meminfo" -TotalCount 5 | Where-Object { $_ -match '^MemAvailable:\s+(\d+)\s+kB' } | Select-Object -First 1
            if ($Line -match '(\d+)\s+kB') { return [int]([long]$Matches[1] / 1024) }
        }
    } catch { }
    return $null
}

function Enter-BKChloeSlot {
    # Prend une des $Total places (fichiers verrouilles dans runtime/chloe-slots). $null si aucune ne se libere avant $TimeoutSec.
    param([string]$Root, [int]$Total = 3, [int]$TimeoutSec = 120, [int]$MinMemoryMb = 400)
    $Dir = Join-Path $Root "runtime/chloe-slots"
    if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    $End = (Get-Date).AddSeconds($TimeoutSec)
    while ($true) {
        $Mem = Get-BKMemAvailableMb
        if ($null -eq $Mem -or $Mem -ge $MinMemoryMb) {
            for ($I = 0; $I -lt $Total; $I++) {
                try {
                    $Fs = [System.IO.File]::Open((Join-Path $Dir "slot-$I.lock"), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
                    return @{ Stream = $Fs; Index = $I }
                } catch [System.IO.IOException] { continue }
                catch { continue }
            }
        }
        if ((Get-Date) -ge $End) { break }
        Start-Sleep -Milliseconds 400
    }
    return $null
}

function Exit-BKChloeSlot {
    param($Slot)
    if ($Slot -and $Slot.Stream) { try { $Slot.Stream.Dispose() } catch { } }
}
