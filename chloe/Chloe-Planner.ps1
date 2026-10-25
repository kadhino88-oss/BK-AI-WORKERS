# =====================================================================
# CHLOE - cheffe de projet : le planificateur (2026-10-25, docs/AUTONOMY-ENGINE.md sections 1.2, 6c.3, 6c.4 et docs/CHLOE-DELEGATION.md).
#
# Transforme l'OBJECTIF du client en un plan BK-PROJECT-PLAN-V1 : des criteres d'acceptation mesurables et des etapes, chacune confiee a UN Worker choisi
# parmi les 17 (jamais hors du forfait du client), avec ses dependances, ses fichiers attendus, son cout estime. Un seul appel au modele fort
# (outil submit_project_plan au schema dur), validation par le code, UN nouvel essai avec la liste des erreurs, puis repli : ancien routage (IA puis
# mots-cles) et plan minimal « une etape par Worker » (plan.fallback = true, affiche comme « plan simplifie »).
#
# SECURITE : le modele ne decide NI des droits NI des credits. La portee (Workers utilisables) et la vue d'usage viennent du serveur (dashboard/
# chloe_scope.py, fenetres d'usage) ; elles sont dans le prompt pour qu'il planifie dans les limites, et le CODE verifie ensuite chaque etape
# (Test-BKProjectPlan). L'objectif, le profil et la memoire du client sont des DONNEES encadrees, jamais des consignes.
#
# A dot-sourcer apres Chloe-Common.ps1 (et Chloe-LegacyRouting.ps1 + Chloe-Router.ps1 pour le repli). Point d'entree du moteur : chloe/Invoke-Chloe-Plan.ps1.
# =====================================================================

$Script:BKProjectMaxSteps = 40
$Script:BKProjectMaxCriteria = 25
$Script:BKProjectEfforts = @("normal", "bulk", "deep")
# Types de controle que le moteur sait executer (docs/AUTONOMY-ENGINE.md 1.2 et 4.2). Un critere « auto » d'un autre type devient un critere a grille.
$Script:BKProjectCheckTypes = @("file_exists", "file_contains", "site_check", "xlsx_check", "docx_check", "csv_check", "json_schema", "approval_executed", "count_matches")
$Script:BKSiteCheckGroups = @("html", "meta", "links", "img", "a11y", "perf", "privacy", "i18n", "seo", "content")

function Test-BKProjectPath {
    # Chemin relatif de l'espace de travail du projet (meme regle que dashboard/project_tools.py) : segments simples, pas de « .. », pas de chemin absolu.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 180 -or $Path.StartsWith("/") -or $Path.Contains("\") -or $Path.Contains([char]0)) { return $false }
    $Segments = $Path.Split("/")
    if ($Segments.Count -gt 8) { return $false }
    foreach ($S in $Segments) { if ($S -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' -or $S -eq "..") { return $false } }
    return $true
}

# ---------------------------------------------------------------------
# Outil de sortie (schema dur)
# ---------------------------------------------------------------------
function Get-BKProjectPlanTool {
    param([string[]]$WorkerIds)
    $Str = [ordered]@{ type = "string" }
    $StrList = [ordered]@{ type = "array"; items = $Str }
    return [ordered]@{
        name = "submit_project_plan"
        description = "Submit the project plan for the client's goal. Call this tool exactly once. The plan has acceptance criteria (measurable; kind auto with a check object when the platform can test it on a file or an approval, otherwise kind rubric with a written rubric) and steps. Every step has ONE owner Worker taken from the available team list, a precise goal, the criteria it serves, the workspace files it reads (inputs) and must produce (expectedOutputs), its dependencies (dependsOn, minimal), an effort (normal, bulk for repetitive volume work, deep only for real judgment), the connectors it needs and an estimate in credits. Outward actions (send, publish, pay, spend, delete) are never steps by themselves: a step prepares them for the client's approval, and publication steps come last. Missing client facts become needsFromClient entries with a default and assumptions, never invented content."
        input_schema = [ordered]@{
            type = "object"
            additionalProperties = $false
            properties = [ordered]@{
                goal = [ordered]@{ type = "string"; description = "The goal restated in one sentence, in the client's language." }
                language = [ordered]@{ type = "string"; description = "Language of the client's goal (fr, en, de...)." }
                recipeId = [ordered]@{ type = "string"; description = "Identifier of the recipe followed, or an empty string." }
                assumptions = [ordered]@{ type = "array"; items = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ id = $Str; text = $Str }; required = @("text") } }
                criteria = [ordered]@{
                    type = "array"; maxItems = 25
                    items = [ordered]@{
                        type = "object"; additionalProperties = $false
                        properties = [ordered]@{
                            id = [ordered]@{ type = "string"; description = "C1, C2, ..." }
                            text = [ordered]@{ type = "string"; description = "What must be true when the project is done." }
                            kind = [ordered]@{ type = "string"; enum = @("auto", "rubric") }
                            check = [ordered]@{ type = "object"; description = "For kind auto: {type: one of the known check types, path, text, profile, must, ...}."; properties = [ordered]@{ type = [ordered]@{ type = "string"; enum = @($Script:BKProjectCheckTypes) } }; required = @("type") }
                            rubric = [ordered]@{ type = "string"; description = "For kind rubric: what to look for and what counts as a failure." }
                        }
                        required = @("id", "text", "kind")
                    }
                }
                steps = [ordered]@{
                    type = "array"; maxItems = 40
                    items = [ordered]@{
                        type = "object"; additionalProperties = $false
                        properties = [ordered]@{
                            id = [ordered]@{ type = "string"; description = "S1, S2, ..." }
                            title = $Str
                            worker = [ordered]@{ type = "string"; enum = @($WorkerIds) }
                            goal = [ordered]@{ type = "string"; description = "Precise instruction for this Worker, in the client's language, keeping the client's facts." }
                            dependsOn = $StrList
                            criteriaIds = $StrList
                            inputs = $StrList
                            expectedOutputs = $StrList
                            effort = [ordered]@{ type = "string"; enum = @($Script:BKProjectEfforts) }
                            connectors = $StrList
                            requiresApprovalsFrom = $StrList
                            estimateCredits = [ordered]@{ type = "integer"; minimum = 0; maximum = 400 }
                        }
                        required = @("id", "title", "worker", "goal")
                    }
                }
                estimate = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ creditsMin = [ordered]@{ type = "integer" }; creditsMax = [ordered]@{ type = "integer" }; hoursMin = [ordered]@{ type = "number" }; hoursMax = [ordered]@{ type = "number" } } }
                needsFromClient = [ordered]@{ type = "array"; items = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ id = $Str; question = $Str; blocking = [ordered]@{ type = "boolean" }; default = $Str }; required = @("question") } }
                risks = $StrList
                unassignable = [ordered]@{ type = "array"; items = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ capability = $Str; bestWorker = $Str; reason = $Str }; required = @("capability") } }
                delegation = [ordered]@{
                    type = "object"; additionalProperties = $false
                    properties = [ordered]@{
                        rationale = [ordered]@{ type = "array"; items = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ stepId = $Str; why = $Str }; required = @("stepId", "why") } }
                        publicFacingSteps = $StrList
                        essentialVariant = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ label = $Str; dropSteps = $StrList } }
                    }
                }
                triage = [ordered]@{ type = "object"; additionalProperties = $false; properties = [ordered]@{ why = $Str } }
            }
            required = @("goal", "criteria", "steps", "estimate")
        }
    }
}

# ---------------------------------------------------------------------
# Controle d'un critere automatique : type connu, chemins valides, valeurs simples. Sinon : le critere devient un critere a grille.
# ---------------------------------------------------------------------
function Get-BKPropNames {
    param($Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys | ForEach-Object { [string]$_ }) }
    return @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function ConvertTo-BKProjectCheck {
    # @{ Ok; Check; Reason }
    param($Raw)
    if ($null -eq $Raw -or $Raw -is [string] -or $Raw -is [System.Array]) { return @{ Ok = $false; Check = $null; Reason = "controle absent" } }
    $Type = ([string](Get-BKProp $Raw "type" "")).Trim().ToLowerInvariant()
    if ($Script:BKProjectCheckTypes -notcontains $Type) { return @{ Ok = $false; Check = $null; Reason = "type de controle inconnu (" + (Limit-BKText -Text $Type -Max 30) + ")" } }
    $Out = [ordered]@{ type = $Type }
    $Count = 0
    foreach ($Name in (Get-BKPropNames $Raw)) {
        if ($Name -eq "type" -or $Name -notmatch '^[A-Za-z][A-Za-z0-9_]{0,31}$') { continue }
        if ($Count -ge 12) { break }
        $V = Get-BKProp $Raw $Name $null
        if ($V -is [string]) { $Out[$Name] = Limit-BKText -Text (Remove-BKControlChars -Text $V) -Max 300 -Marker "" }
        elseif ($V -is [bool] -or $V -is [int] -or $V -is [long] -or $V -is [double]) { $Out[$Name] = $V }
        elseif ($V -is [System.Collections.IEnumerable]) {
            $Items = @(@($V) | Where-Object { $_ -is [string] -or $_ -is [int] -or $_ -is [long] -or $_ -is [double] } | Select-Object -First 20 | ForEach-Object { if ($_ -is [string]) { Limit-BKText -Text (Remove-BKControlChars -Text $_) -Max 200 -Marker "" } else { $_ } })
            $Out[$Name] = $Items
        }
        else { continue }
        $Count++
    }
    foreach ($PathKey in @("path", "file")) {
        if ($Out.Contains($PathKey) -and -not (Test-BKProjectPath ([string]$Out[$PathKey]))) { return @{ Ok = $false; Check = $null; Reason = "chemin invalide ($PathKey)" } }
    }
    $NeedsPath = @("file_exists", "file_contains", "xlsx_check", "docx_check", "csv_check", "json_schema", "count_matches")
    if ($NeedsPath -contains $Type -and -not $Out.Contains("path")) { return @{ Ok = $false; Check = $null; Reason = "chemin manquant" } }
    if ($Type -eq "file_contains" -and -not ($Out.Contains("text") -or $Out.Contains("pattern") -or $Out.Contains("contains"))) { return @{ Ok = $false; Check = $null; Reason = "texte cherche manquant" } }
    if ($Type -eq "approval_executed" -and -not ($Out.Contains("connector") -and $Out.Contains("operation"))) { return @{ Ok = $false; Check = $null; Reason = "connecteur ou operation manquant" } }
    if ($Type -eq "site_check") {
        if (-not $Out.Contains("profile") -or @("vitrine", "landing", "blog") -notcontains [string]$Out["profile"]) { $Out["profile"] = "vitrine" }
        $Must = @(@($Out["must"]) | Where-Object { $Script:BKSiteCheckGroups -contains [string]$_ })
        $Out["must"] = $(if ($Must.Count -gt 0) { $Must } else { @("html", "meta", "links") })
    }
    return @{ Ok = $true; Check = $Out; Reason = "" }
}

# ---------------------------------------------------------------------
# Validation et normalisation du plan (le CODE decide, jamais le modele)
# ---------------------------------------------------------------------
function Test-BKProjectPlan {
    # @{ Ok; Errors = [FR] ; Warnings = [FR] ; Plan }.  $Allowed = Workers que le client peut utiliser ; $Roster = tous les Workers connus.
    param(
        $Raw,
        [string[]]$Allowed,
        [string[]]$Roster,
        $AllowedNow = $null,
        $Cards = $null,
        [string]$Goal = "",
        [string]$Language = "fr",
        [int]$MaxSteps = $Script:BKProjectMaxSteps,
        [int]$MaxCriteria = $Script:BKProjectMaxCriteria
    )
    $Errors = @()
    $Warnings = @()
    if ($null -eq $Raw -or $Raw -is [string] -or $Raw -is [System.Array]) {
        return @{ Ok = $false; Errors = @("Le plan doit etre un objet JSON avec les champs goal, criteria, steps et estimate."); Warnings = @(); Plan = $null }
    }

    # ---- criteres
    $RawCriteria = @(Get-BKProp $Raw "criteria" @() | Where-Object { $null -ne $_ })
    if ($RawCriteria.Count -eq 0) { $Errors += "Au moins un critere d'acceptation (criteria) est requis." }
    if ($RawCriteria.Count -gt $MaxCriteria) { $Errors += "Au plus $MaxCriteria criteres : regroupez-les." }
    $Criteria = @()
    $CritIds = @{}
    $Index = 0
    foreach ($C in ($RawCriteria | Select-Object -First $MaxCriteria)) {
        $Index++
        $Id = ([string](Get-BKProp $C "id" "")).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "C$Index" }
        if ($Id -notmatch '^C[0-9]{1,2}$') { $Errors += "Identifiant de critere invalide : $Id (attendu : C1, C2...)."; continue }
        if ($CritIds.ContainsKey($Id)) { $Errors += "Identifiant de critere en double : $Id."; continue }
        $Text = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $C "text" ""))).Trim() -Max 300)
        if ($Text.Length -lt 8) { $Errors += "Critere ${Id} : texte manquant ou trop court."; continue }
        $RawKind = ([string](Get-BKProp $C "kind" "")).Trim().ToLowerInvariant()
        $RawCheck = Get-BKProp $C "check" $null
        $Kind = if ($RawKind -eq "auto" -or ($RawKind -ne "rubric" -and $null -ne $RawCheck)) { "auto" } else { "rubric" }
        $Rubric = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $C "rubric" ""))).Trim() -Max 600)
        $Check = $null
        if ($Kind -eq "auto") {
            $Norm = ConvertTo-BKProjectCheck -Raw $RawCheck
            if ($Norm.Ok) { $Check = $Norm.Check }
            else {
                $Kind = "rubric"
                $Warnings += "Critere ${Id} : controle automatique non utilisable ($($Norm.Reason)), converti en critere a grille."
            }
        }
        if ($Kind -eq "rubric" -and $Rubric.Length -lt 10) { $Rubric = $Text }
        $CritIds[$Id] = $true
        $Row = [ordered]@{ id = $Id; text = $Text; kind = $Kind }
        if ($Kind -eq "auto") { $Row["check"] = $Check } else { $Row["rubric"] = $Rubric }
        $Criteria += $Row
    }

    # ---- etapes
    $RawSteps = @(Get-BKProp $Raw "steps" @() | Where-Object { $null -ne $_ })
    if ($RawSteps.Count -eq 0) { $Errors += "Au moins une etape (steps) est requise." }
    if ($RawSteps.Count -gt $MaxSteps) { $Errors += "Au plus $MaxSteps etapes : regroupez-les." }
    $Steps = @()
    $StepIds = @{}
    $Index = 0
    foreach ($S in ($RawSteps | Select-Object -First $MaxSteps)) {
        $Index++
        $Id = ([string](Get-BKProp $S "id" "")).Trim().ToUpperInvariant()
        if ([string]::IsNullOrWhiteSpace($Id)) { $Id = "S$Index" }
        if ($Id -notmatch '^S[0-9]{1,2}$') { $Errors += "Identifiant d'etape invalide : $Id (attendu : S1, S2...)."; continue }
        if ($StepIds.ContainsKey($Id)) { $Errors += "Identifiant d'etape en double : $Id."; continue }
        $Worker = ([string](Get-BKProp $S "worker" "")).Trim().ToLowerInvariant()
        if ($Worker -notmatch '^[a-z]{2,20}$' -or ($Roster -notcontains $Worker)) {
            $Errors += "Etape ${Id} : Worker inconnu ou invalide (" + (Limit-BKText -Text $Worker -Max 24) + "). Choisissez un identifiant de la liste de l'equipe."
            continue
        }
        if ($Allowed -notcontains $Worker) {
            $Errors += "Etape ${Id} : le Worker $Worker est INDISPONIBLE pour ce client. Aucune etape ne peut lui etre confiee : mettez cette partie dans unassignable (bestWorker $Worker) et poursuivez avec les Workers disponibles."
            continue
        }
        $Title = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $S "title" ""))).Trim() -Max 120)
        $StepGoal = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $S "goal" ""))).Trim() -Max 1500)
        if ($Title.Length -lt 3) { $Errors += "Etape ${Id} : titre manquant."; continue }
        if ($StepGoal.Length -lt 12) { $Errors += "Etape ${Id} : objectif (goal) manquant ou trop court."; continue }
        $Effort = ([string](Get-BKProp $S "effort" "normal")).Trim().ToLowerInvariant()
        if ($Script:BKProjectEfforts -notcontains $Effort) { $Effort = "normal" }
        $Estimate = 0
        $RawEst = Get-BKProp $S "estimateCredits" 0
        if ($RawEst -is [int] -or $RawEst -is [long] -or $RawEst -is [double]) { $Estimate = [int][Math]::Max(0, [Math]::Min(400, [Math]::Round([double]$RawEst))) }
        $Paths = @{}
        foreach ($Key in @("inputs", "expectedOutputs")) {
            $List = @()
            foreach ($P in @(Get-BKProp $S $Key @() | Where-Object { $null -ne $_ } | Select-Object -First 12)) {
                $Pv = ([string]$P).Trim()
                if (Test-BKProjectPath $Pv) { $List += $Pv } else { $Errors += "Etape ${Id} : chemin invalide dans $Key ($(Limit-BKText -Text $Pv -Max 60)) : chemin relatif sans « .. », segments simples (lettres, chiffres, point, tiret)." }
            }
            $Paths[$Key] = $List
        }
        $Conn = @(@(Get-BKProp $S "connectors" @()) | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ -match '^[a-z][a-z0-9_]{1,31}$' } | Select-Object -Unique -First 8)
        $StepIds[$Id] = $true
        $Steps += [ordered]@{
            id = $Id; title = $Title; worker = $Worker; goal = $StepGoal
            dependsOn = @(@(Get-BKProp $S "dependsOn" @()) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            criteriaIds = @(@(Get-BKProp $S "criteriaIds" @()) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            inputs = @($Paths["inputs"]); expectedOutputs = @($Paths["expectedOutputs"]); effort = $Effort; connectors = @($Conn)
            requiresApprovalsFrom = @(@(Get-BKProp $S "requiresApprovalsFrom" @()) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $_ } | Select-Object -Unique)
            estimateCredits = $Estimate
        }
    }

    # ---- liens entre etapes et criteres
    foreach ($T in $Steps) {
        foreach ($D in $T.dependsOn) {
            if ($D -eq $T.id) { $Errors += "Etape $($T.id) : depend d'elle-meme." }
            elseif (-not $StepIds.ContainsKey($D)) { $Errors += "Etape $($T.id) : depend de $D qui n'existe pas." }
        }
        foreach ($A in $T.requiresApprovalsFrom) {
            if (-not $StepIds.ContainsKey($A)) { $Errors += "Etape $($T.id) : requiresApprovalsFrom cite $A qui n'existe pas." }
        }
        foreach ($K in $T.criteriaIds) {
            if (-not $CritIds.ContainsKey($K)) { $Errors += "Etape $($T.id) : critere $K inexistant dans criteria." }
        }
        if ($T.criteriaIds.Count -eq 0) { $Warnings += "Etape $($T.id) ne cite aucun critere." }
    }
    $Covered = @{}
    foreach ($T in $Steps) { foreach ($K in $T.criteriaIds) { $Covered[$K] = $true } }
    foreach ($C in $Criteria) {
        if (-not $Covered.ContainsKey($C.id)) { $Errors += "Le critere $($C.id) n'est couvert par aucune etape : ajoutez-le dans criteriaIds de l'etape qui le satisfait." }
    }
    $Order = $null
    if ($Errors.Count -eq 0 -and $Steps.Count -gt 0) {
        $Order = Get-BKTaskOrder -Tasks $Steps
        if ($null -eq $Order) { $Errors += "Les dependances des etapes forment un cycle : un plan doit etre un graphe sans boucle." }
    }
    # Les etapes de publication ou d'envoi viennent EN DERNIER : elles dependent (directement ou non) de toutes les autres etapes.
    if ($Errors.Count -eq 0 -and $Steps.Count -gt 1) {
        $ById = @{}; foreach ($T in $Steps) { $ById[$T.id] = $T }
        $Ancestors = @{}
        foreach ($Id in $Order) {
            $Set = @{}
            foreach ($D in $ById[$Id].dependsOn) { $Set[$D] = $true; foreach ($A in $Ancestors[$D].Keys) { $Set[$A] = $true } }
            $Ancestors[$Id] = $Set
        }
        $PubRx = '^(?i)(publication|publier|publish|mise en ligne|go live|envoi (de|des|du|d.)|lancement en ligne)\b'
        $Pubs = @($Steps | Where-Object { $_.title -match $PubRx })
        foreach ($P in $Pubs) {
            $Missing = @($Steps | Where-Object { $_.id -ne $P.id -and ($Pubs.id -notcontains $_.id) -and -not $Ancestors[$P.id].ContainsKey($_.id) } | ForEach-Object { $_.id })
            if ($Missing.Count -gt 0) { $Errors += "Etape $($P.id) (publication ou envoi) : elle doit venir en dernier et dependre de toutes les autres etapes (il manque : $($Missing -join ', '))." }
        }
    }

    # ---- delegation (rationale par etape, etapes destinees au public, variante « Essentiel »)
    $RawDeleg = Get-BKProp $Raw "delegation" $null
    $Rationale = @()
    $RatByStep = @{}
    foreach ($R in @(Get-BKProp $RawDeleg "rationale" @() | Where-Object { $null -ne $_ })) {
        $Sid = ([string](Get-BKProp $R "stepId" "")).Trim().ToUpperInvariant()
        if ($StepIds.ContainsKey($Sid) -and -not $RatByStep.ContainsKey($Sid)) { $RatByStep[$Sid] = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $R "why" ""))).Trim() -Max 240) }
    }
    foreach ($T in $Steps) {
        $Why = $RatByStep[$T.id]
        if ([string]::IsNullOrWhiteSpace($Why)) {
            $Role = if ($Cards -and $Cards.ContainsKey($T.worker)) { [string]$Cards[$T.worker].role } else { "" }
            $Why = "$(Get-BKWorkerDisplayName -Cards $Cards -Id $T.worker)$(if ($Role) { ' (' + $Role + ')' }) : metier de cette etape."
        }
        $Rationale += [ordered]@{ stepId = $T.id; worker = $T.worker; why = $Why }
    }
    $PublicSteps = @(@(Get-BKProp $RawDeleg "publicFacingSteps" @()) | ForEach-Object { ([string]$_).Trim().ToUpperInvariant() } | Where-Object { $StepIds.ContainsKey($_) } | Select-Object -Unique)
    $PublicWorkers = @($Steps | Where-Object { $PublicSteps -contains $_.id } | ForEach-Object { $_.worker } | Select-Object -Unique)

    # ---- estimation : toujours coherente avec la somme des etapes
    $Sum = 0; foreach ($T in $Steps) { $Sum += [int]$T.estimateCredits }
    $RawEstimate = Get-BKProp $Raw "estimate" $null
    $CMin = Get-BKProp $RawEstimate "creditsMin" $null
    $CMax = Get-BKProp $RawEstimate "creditsMax" $null
    $HMin = Get-BKProp $RawEstimate "hoursMin" $null
    $HMax = Get-BKProp $RawEstimate "hoursMax" $null
    $NumOk = { param($V) ($V -is [int] -or $V -is [long] -or $V -is [double]) -and [double]$V -ge 0 }
    $CreditsMin = if (& $NumOk $CMin) { [int][Math]::Round([double]$CMin) } else { [int][Math]::Round($Sum * 0.8) }
    $CreditsMax = if (& $NumOk $CMax) { [int][Math]::Round([double]$CMax) } else { [int][Math]::Round($Sum * 1.4) }
    if ($CreditsMax -lt $CreditsMin) { $CreditsMax = $CreditsMin }
    if ($Sum -gt 0 -and ($CreditsMin -gt $Sum -or $CreditsMax -lt $Sum)) {
        $Warnings += "Estimation corrigee pour contenir la somme des etapes ($Sum credits)."
        $CreditsMin = [Math]::Min($CreditsMin, $Sum); $CreditsMax = [Math]::Max($CreditsMax, $Sum)
    }
    $HoursMin = if (& $NumOk $HMin) { [Math]::Round([double]$HMin, 1) } else { [Math]::Round([Math]::Max(0.2, $Steps.Count * 0.1), 1) }
    $HoursMax = if (& $NumOk $HMax) { [Math]::Round([double]$HMax, 1) } else { [Math]::Round([Math]::Max($HoursMin, $Steps.Count * 0.3), 1) }
    if ($HoursMax -lt $HoursMin) { $HoursMax = $HoursMin }

    $Variant = $null
    $RawVariant = Get-BKProp $RawDeleg "essentialVariant" $null
    if ($null -ne $RawVariant -and $Steps.Count -gt 1) {
        $Drop = @{}
        foreach ($D in @(Get-BKProp $RawVariant "dropSteps" @())) { $Du = ([string]$D).Trim().ToUpperInvariant(); if ($StepIds.ContainsKey($Du)) { $Drop[$Du] = $true } }
        $Grew = $true
        while ($Grew) {        # une etape qui depend d'une etape retiree est retiree aussi
            $Grew = $false
            foreach ($T in $Steps) { if (-not $Drop.ContainsKey($T.id) -and @($T.dependsOn | Where-Object { $Drop.ContainsKey($_) }).Count -gt 0) { $Drop[$T.id] = $true; $Grew = $true } }
        }
        $Kept = @($Steps | Where-Object { -not $Drop.ContainsKey($_.id) })
        if ($Drop.Count -gt 0 -and $Kept.Count -gt 0) {
            $KeptSum = 0; foreach ($T in $Kept) { $KeptSum += [int]$T.estimateCredits }
            $KeptCovered = @{}; foreach ($T in $Kept) { foreach ($K in $T.criteriaIds) { $KeptCovered[$K] = $true } }
            $Variant = [ordered]@{
                label = $(if ([string]::IsNullOrWhiteSpace([string](Get-BKProp $RawVariant "label" ""))) { "Essentiel" } else { Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $RawVariant "label" ""))).Trim() -Max 60 })
                dropSteps = @($Steps | Where-Object { $Drop.ContainsKey($_.id) } | ForEach-Object { $_.id })
                creditsMin = [int][Math]::Round($KeptSum * 0.8); creditsMax = [int][Math]::Round($KeptSum * 1.4)
                droppedCriteria = @($Criteria | Where-Object { -not $KeptCovered.ContainsKey($_.id) } | ForEach-Object { $_.id })
            }
        }
    }
    if ($null -ne $AllowedNow -and $CreditsMin -gt [int]$AllowedNow -and $null -eq $Variant) {
        $Warnings += "L'estimation ($CreditsMin a $CreditsMax credits) depasse les credits utilisables maintenant ($AllowedNow) et aucune variante Essentiel n'est proposee."
    }

    # ---- le reste : hypotheses, questions, risques, ce qui ne peut pas etre confie
    $Assumptions = @()
    $AI = 0
    foreach ($A in @(Get-BKProp $Raw "assumptions" @() | Where-Object { $null -ne $_ } | Select-Object -First 12)) {
        $AI++
        $At = if ($A -is [string]) { $A } else { [string](Get-BKProp $A "text" "") }
        $At = (Limit-BKText -Text (Remove-BKControlChars -Text $At).Trim() -Max 300)
        if ($At) { $Assumptions += [ordered]@{ id = "A$AI"; text = $At } }
    }
    $Needs = @()
    $QI = 0
    foreach ($Q in @(Get-BKProp $Raw "needsFromClient" @() | Where-Object { $null -ne $_ } | Select-Object -First 12)) {
        $QI++
        $Qt = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $Q "question" ""))).Trim() -Max 300)
        if (-not $Qt) { continue }
        $Needs += [ordered]@{ id = "Q$QI"; question = $Qt; blocking = ((Get-BKProp $Q "blocking" $false) -eq $true); default = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $Q "default" ""))).Trim() -Max 300) }
    }
    if (@($Needs | Where-Object { $_.blocking }).Count -gt 3) {
        $Seen = 0
        $Needs = @($Needs | ForEach-Object { if ($_.blocking) { $Seen++; if ($Seen -gt 3) { $_.blocking = $false } }; $_ })
        $Warnings += "Plus de 3 questions bloquantes : les suivantes sont devenues non bloquantes (valeur par defaut)."
    }
    $Risks = @(@(Get-BKProp $Raw "risks" @()) | ForEach-Object { Limit-BKText -Text (Remove-BKControlChars -Text ([string]$_)).Trim() -Max 300 } | Where-Object { $_ } | Select-Object -First 10)
    $Unassignable = @()
    foreach ($U in @(Get-BKProp $Raw "unassignable" @() | Where-Object { $null -ne $_ } | Select-Object -First 10)) {
        $Cap = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $U "capability" ""))).Trim() -Max 200)
        if (-not $Cap) { continue }
        $Best = ([string](Get-BKProp $U "bestWorker" "")).Trim().ToLowerInvariant()
        if ($Roster -notcontains $Best) { $Best = "" }
        $Unassignable += [ordered]@{ capability = $Cap; bestWorker = $Best; reason = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $U "reason" ""))).Trim() -Max 300) }
    }

    if ($Errors.Count -gt 0) { return @{ Ok = $false; Errors = $Errors; Warnings = $Warnings; Plan = $null } }
    $GoalText = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp $Raw "goal" ""))).Trim() -Max 400)
    if (-not $GoalText) { $GoalText = Limit-BKText -Text $Goal -Max 400 }
    $Lang = ([string](Get-BKProp $Raw "language" "")).Trim().ToLowerInvariant()
    if ($Lang -notmatch '^[a-z]{2,3}(-[a-z]{2,4})?$') { $Lang = $Language }
    $RecipeId = ([string](Get-BKProp $Raw "recipeId" "")).Trim().ToLowerInvariant()
    if ($RecipeId -notmatch '^[a-z]{2,20}/[a-z0-9][a-z0-9-]{1,60}$') { $RecipeId = "" }
    $Plan = [ordered]@{
        schema = "BK-PROJECT-PLAN-V1"; version = 1; goal = $GoalText; language = $Lang; recipeId = $RecipeId
        assumptions = @($Assumptions); criteria = @($Criteria); steps = @($Steps)
        estimate = [ordered]@{ creditsMin = $CreditsMin; creditsMax = $CreditsMax; hoursMin = $HoursMin; hoursMax = $HoursMax }
        needsFromClient = @($Needs); risks = @($Risks); unassignable = @($Unassignable)
        delegation = [ordered]@{
            lead = "chloe"
            workers = @($Steps | ForEach-Object { $_.worker } | Select-Object -Unique)
            rationale = @($Rationale)
            publicFacingSteps = @($PublicSteps)
            consistency = [ordered]@{ required = ($PublicWorkers.Count -ge 2); workers = @($PublicWorkers) }
            essentialVariant = $Variant
            hireOffer = @()
        }
        triage = [ordered]@{ mode = "project"; why = (Limit-BKText -Text (Remove-BKControlChars -Text ([string](Get-BKProp (Get-BKProp $Raw "triage" $null) "why" ""))).Trim() -Max 300) }
        fallback = $false
    }
    return @{ Ok = $true; Errors = @(); Warnings = $Warnings; Plan = $Plan }
}

# ---------------------------------------------------------------------
# Repli : plan minimal « une etape par Worker » (ancien routage), explicitement marque comme simplifie
# ---------------------------------------------------------------------
function New-BKFallbackProjectPlan {
    param(
        [Parameter(Mandatory=$true)][string]$Goal,
        [AllowEmptyCollection()][string[]]$WorkerIds = @(),      # Workers retenus par l'ancien routage (dans leur ordre) ; aucun : le generaliste
        [string[]]$Allowed,
        $Cards = $null,
        $Denied = @(),
        [string]$Language = "fr",
        [switch]$Chain,
        [string]$Source = "keywords"
    )
    $Usable = @($WorkerIds | Where-Object { $Allowed -contains $_ } | Select-Object -Unique)
    $Lost = @($WorkerIds | Where-Object { $Allowed -notcontains $_ } | Select-Object -Unique)
    if ($Usable.Count -eq 0) {
        $Generalist = if ($Allowed -contains "noah") { "noah" } else { @($Allowed | Select-Object -First 1)[0] }
        if ([string]::IsNullOrWhiteSpace($Generalist)) { return $null }
        $Usable = @($Generalist)
    }
    $Steps = @()
    $Rationale = @()
    $Index = 0
    foreach ($W in $Usable) {
        $Index++
        $Name = Get-BKWorkerDisplayName -Cards $Cards -Id $W
        $Typical = if ($Cards -and $Cards.ContainsKey($W) -and @($Cards[$W].typicalStepCredits).Count -ge 2) { [int][Math]::Round(([double]$Cards[$W].typicalStepCredits[0] + [double]$Cards[$W].typicalStepCredits[1]) / 2) } else { 8 }
        $Steps += [ordered]@{
            id = "S$Index"; title = "Part de $Name"; worker = $W
            goal = (Limit-BKText -Text $Goal -Max 1500)
            dependsOn = @(if ($Chain -and $Index -gt 1) { "S" + ($Index - 1) }); criteriaIds = @("C1"); inputs = @()
            expectedOutputs = @("deliverables/$W.md"); effort = "normal"; connectors = @(); requiresApprovalsFrom = @(); estimateCredits = $Typical
        }
        $Rationale += [ordered]@{ stepId = "S$Index"; worker = $W; why = $(if ($Source -eq "keywords") { "Choisi par mots-cles de routage (plan simplifie)." } else { "Choisi par l'ancien routage (plan simplifie)." }) }
    }
    $Sum = 0; foreach ($T in $Steps) { $Sum += [int]$T.estimateCredits }
    $Unassignable = @()
    foreach ($W in $Lost) {
        $Reason = "Ne fait pas partie de vos Workers : embauchez-le pour lui confier cette partie."
        foreach ($D in @($Denied)) { if ([string](Get-BKProp $D "workerId" "") -eq $W -and (Get-BKProp $D "reason" "")) { $Reason = [string](Get-BKProp $D "reason" ""); break } }
        $Unassignable += [ordered]@{ capability = "Partie de l'objectif relevant de $(Get-BKWorkerDisplayName -Cards $Cards -Id $W)"; bestWorker = $W; reason = $Reason }
    }
    return [ordered]@{
        schema = "BK-PROJECT-PLAN-V1"; version = 1; goal = (Limit-BKText -Text $Goal -Max 400); language = $Language; recipeId = ""
        assumptions = @([ordered]@{ id = "A1"; text = "Plan simplifie : l'objectif n'a pas pu etre decoupe finement ; chaque Worker retenu traite la partie de l'objectif qui releve de son metier." })
        criteria = @([ordered]@{ id = "C1"; text = "Chaque Worker a livre, dans un fichier du projet, la partie de l'objectif qui releve de son metier."; kind = "rubric"
                rubric = "Un livrable existe pour chaque Worker, il repond a l'objectif du client, n'invente aucun fait (avis, temoignage, chiffre, certification) et signale par [A COMPLETER : ...] ce que le client doit fournir." })
        steps = @($Steps)
        estimate = [ordered]@{ creditsMin = [int][Math]::Round($Sum * 0.8); creditsMax = [int][Math]::Round($Sum * 1.4); hoursMin = [Math]::Round([Math]::Max(0.2, $Steps.Count * 0.1), 1); hoursMax = [Math]::Round([Math]::Max(0.3, $Steps.Count * 0.3), 1) }
        needsFromClient = @(); risks = @("Plan simplifie : verifiez-le avant de lancer.")
        unassignable = @($Unassignable)
        delegation = [ordered]@{
            lead = "chloe"; workers = @($Usable); rationale = @($Rationale); publicFacingSteps = @()
            consistency = [ordered]@{ required = $false; workers = @() }; essentialVariant = $null; hireOffer = @($Lost)
        }
        triage = [ordered]@{ mode = "project"; why = "Plan simplifie (repli)." }
        fallback = $true
    }
}

# ---------------------------------------------------------------------
# Modele et contexte
# ---------------------------------------------------------------------
function Get-BKProjectPlanModel {
    # Phase « plan » : core/ai/PROJECT-PHASES.json (levelRef -> core/ai/LEVELS.json) quand il existe ; sinon le niveau Approfondi. Surcharge de test :
    # BK_CHLOE_PLANNER_MODEL.
    param([string]$Root)
    $Model = "claude-opus-5-5"; $Effort = "high"
    try {
        $Levels = Read-BKJsonFile -Path (Join-Path $Root "core/ai/LEVELS.json")
        $Ref = "approfondi"
        $Phases = Read-BKJsonFile -Path (Join-Path $Root "core/ai/PROJECT-PHASES.json")
        if ($Phases) {
            $Ph = Get-BKProp (Get-BKProp $Phases "phases" $Phases) "plan" $null
            if ($Ph -and (Get-BKProp $Ph "levelRef" "")) { $Ref = [string](Get-BKProp $Ph "levelRef" "") }
        }
        $Lv = Get-BKProp (Get-BKProp $Levels "levels" $null) $Ref $null
        if ($Lv) {
            if (Get-BKProp $Lv "model" "") { $Model = [string](Get-BKProp $Lv "model" "") }
            if (Get-BKProp $Lv "effort" "") { $Effort = [string](Get-BKProp $Lv "effort" "") }
        }
    } catch { }
    if ($env:BK_CHLOE_PLANNER_MODEL -match '^claude-[a-z0-9.-]{3,40}$') { $Model = [string]$env:BK_CHLOE_PLANNER_MODEL }
    return @{ Model = $Model; Effort = $Effort }
}

function Get-BKChloeClientContext {
    # Profil entreprise et notes durables du client (memes sources que Get-WorkerSystemPrompt) : DONNEES, encadrees par l'appelant.
    param([string]$Root, [string]$ClientId)
    $Lines = @()
    if ($ClientId -match '^[A-Za-z0-9_-]+$') {
        $ProfilePath = Join-Path $Root ("core/profile/data/" + $ClientId + ".json")
        if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
            try {
                $P = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($P.companyName) { $Lines += "- Company: $($P.companyName)" }
                if ($P.sector) { $Lines += "- Industry: $($P.sector)" }
                if ($P.description) { $Lines += "- Business: $($P.description)" }
            } catch { }
        }
        $MemScript = Join-Path $Root "core/ai/adapters/Client-Memory.ps1"
        if (Test-Path -LiteralPath $MemScript -PathType Leaf) {
            try { . $MemScript; $Mem = [string](Get-BKMemoryBlock -Root $Root -ClientId $ClientId); if ($Mem.Trim()) { $Lines += $Mem.Trim() } } catch { }
        }
    }
    return (Limit-BKText -Text ($Lines -join "`n") -Max 4000)
}

function Format-BKPlannerTeam {
    param($Cards, [string[]]$Roster, [string[]]$Allowed)
    $Out = @()
    foreach ($Id in $Roster) {
        $C = $Cards[$Id]
        $Line = Format-BKChloeCardLine -Card $C
        if (@($C.connectors).Count -gt 0) { $Line += " Connectors: " + ((@($C.connectors) | Select-Object -First 8) -join ", ") + "." }
        if (@($C.typicalStepCredits).Count -ge 2) { $Line += " Typical credits per step: $($C.typicalStepCredits[0])-$($C.typicalStepCredits[1])." }
        if (@($C.recipes).Count -gt 0) { $Line += " Recipes: " + (@($C.recipes) -join ", ") + "." }
        if ($Allowed -notcontains $Id) { $Line = "[UNAVAILABLE for this client] " + $Line }
        $Out += $Line
    }
    return ($Out -join "`n")
}

function Format-BKPlannerScope {
    param([string[]]$Allowed, $Denied, [bool]$HireOffer)
    $Text = "Available Workers: " + $(if ($Allowed.Count -gt 0) { $Allowed -join ", " } else { "(none)" }) + "."
    $Names = @(@($Denied) | ForEach-Object { [string](Get-BKProp $_ "workerId" "") } | Where-Object { $_ })
    if ($Names.Count -gt 0) {
        $Text += "`nUNAVAILABLE for this client (not part of their plan, NEVER assign a step to them): " + ($Names -join ", ") + ". If part of the goal belongs to one of them, put it in unassignable[] with that Worker as bestWorker: the platform will tell the client and offer to hire them."
    }
    return $Text
}

function Format-BKPlannerUsage {
    param($Usage)
    if ($null -eq $Usage) { return "No usage information: do not assume a credit limit, but keep the plan as small as the goal allows." }
    $Now = Get-BKProp $Usage "allowedNow" $null
    $Lines = @()
    if ($null -ne $Now) { $Lines += "Credits the client can spend right now: $Now (the lowest of their session, week and month allowances)." }
    foreach ($W in @("session", "week", "month")) {
        $Rem = Get-BKProp (Get-BKProp $Usage $W $null) "remaining" $null
        if ($null -ne $Rem) { $Lines += "- $W remaining: $Rem" }
    }
    $Binding = [string](Get-BKProp $Usage "binding" "")
    if ($Binding) { $Lines += "Binding window: $Binding." }
    $Cost = Get-BKProp $Usage "creditCostChf" $null
    if ($null -ne $Cost) { $Lines += "One credit = $Cost CHF." }
    $Lines += "A plan whose minimum estimate is above what the client can spend right now still gets proposed, but it MUST come with delegation.essentialVariant (a smaller plan). Do not shrink the plan silently."
    return ($Lines -join "`n")
}

function Get-BKPlannerSystemPrompt {
    param([string]$Root, $Cards, [string[]]$Roster, [string[]]$Allowed, $Denied, [bool]$HireOffer, $Usage, [string]$RecipesBlock, [string]$Lang)
    $TemplatePath = Join-Path $Root "chloe/prompts/plan.md"
    $Template = ""
    if (Test-Path -LiteralPath $TemplatePath -PathType Leaf) { $Template = [System.IO.File]::ReadAllText($TemplatePath, [System.Text.UTF8Encoding]::new($false)).TrimStart([char]0xFEFF) }
    if ([string]::IsNullOrWhiteSpace($Template)) { throw "PLAN_TEMPLATE_MISSING" }
    $Recipes = ""
    if (-not [string]::IsNullOrWhiteSpace($RecipesBlock)) { $Recipes = "RECIPES THAT MAY FIT (platform-authored guidance; follow one when it fits the goal)`n" + (Limit-BKText -Text $RecipesBlock -Max 9000) }
    $Map = [ordered]@{
        "{{TEAM}}" = (Format-BKPlannerTeam -Cards $Cards -Roster $Roster -Allowed $Allowed)
        "{{SCOPE}}" = (Format-BKPlannerScope -Allowed $Allowed -Denied $Denied -HireOffer $HireOffer)
        "{{USAGE}}" = (Format-BKPlannerUsage -Usage $Usage)
        "{{RECIPES}}" = $Recipes
        "{{CHECKS}}" = ($Script:BKProjectCheckTypes -join ", ")
        "{{LANG}}" = $(if ($Lang) { $Lang } else { "the language of the client's goal" })
    }
    foreach ($K in $Map.Keys) { $Template = $Template.Replace($K, [string]$Map[$K]) }
    return $Template
}

function Add-BKUsageTotals {
    param($Total, $Usage)
    if ($null -eq $Usage) { return $Total }
    foreach ($F in @("input_tokens", "output_tokens", "api_calls")) { $Total[$F] = [long]$Total[$F] + [long](Get-BKProp $Usage $F 0) }
    foreach ($F in @("estimated_cost_usd", "estimated_cost_chf")) { $V = Get-BKProp $Usage $F $null; if ($null -ne $V) { $Total[$F] = [double]$Total[$F] + [double]$V } }
    return $Total
}

# ---------------------------------------------------------------------
# Le planificateur
# ---------------------------------------------------------------------
function Invoke-BKChloePlan {
    # @{ Ok; Source ("model"|"fallback"); Plan; Errors; Warnings; Usage; Attempts; Model; FallbackReason }
    # $Scope = { chloe, allowed[], denied[{workerId, reason}], hireOffer }. $Usage = vue d'usage (allowedNow, binding, session/week/month.remaining).
    param(
        [Parameter(Mandatory=$true)][string]$Goal,
        [Parameter(Mandatory=$true)][string]$Root,
        [Parameter(Mandatory=$true)]$Scope,
        $RoutingConfig = $null,
        $Cards = $null,
        $Usage = $null,
        [string]$Language = "",
        [string]$ClientId = "",
        [string]$RecipesBlock = "",
        [string]$InputsNote = "",
        [switch]$Chain,
        [int]$MaxAttempts = 2
    )
    if ($null -eq $RoutingConfig) { $RoutingConfig = Read-BKJsonFile -Path (Join-Path $Root "orchestrator/worker-routing.json") }
    if ($null -eq $Cards) { $Cards = Get-BKChloeCards -Root $Root -RoutingConfig $RoutingConfig }
    $Roster = @(Get-BKChloeRosterIds -RoutingConfig $RoutingConfig)
    $Allowed = @(@(Get-BKProp $Scope "allowed" @()) | ForEach-Object { ([string]$_).ToLowerInvariant() } | Where-Object { $Roster -contains $_ })
    $Denied = @(Get-BKProp $Scope "denied" @() | Where-Object { $null -ne $_ })
    $HireOffer = ((Get-BKProp $Scope "hireOffer" $false) -eq $true)
    $AllowedNow = Get-BKProp $Usage "allowedNow" $null
    $Totals = @{ input_tokens = 0; output_tokens = 0; api_calls = 0; estimated_cost_usd = 0.0; estimated_cost_chf = 0.0 }
    $Errors = @()
    $Warnings = @()
    $FallbackReason = ""
    $Phase = Get-BKProjectPlanModel -Root $Root
    $Attempts = 0

    if ((Get-BKProp $Scope "chloe" $true) -ne $true -or $Allowed.Count -eq 0) {
        return @{ Ok = $false; Source = "none"; Plan = $null; Errors = @("NO_WORKER_IN_SCOPE"); Warnings = @(); Usage = $Totals; Attempts = 0; Model = $Phase.Model; FallbackReason = "NO_WORKER_IN_SCOPE" }
    }

    $System = Get-BKPlannerSystemPrompt -Root $Root -Cards $Cards -Roster $Roster -Allowed $Allowed -Denied $Denied -HireOffer $HireOffer -Usage $Usage -RecipesBlock $RecipesBlock -Lang $Language
    $Tool = Get-BKProjectPlanTool -WorkerIds $Allowed
    $ClientContext = Get-BKChloeClientContext -Root $Root -ClientId $ClientId
    $UserBase = "Plan this project.`n`n" + (New-BKDataFence -Tag "client_goal" -Text $Goal -Max 4000)
    if ($ClientContext) { $UserBase += "`n`nWhat the platform already knows about this client (data, use it, do not ask for it again):`n" + (New-BKDataFence -Tag "client_memory" -Text $ClientContext -Max 4000) }
    if ($InputsNote) { $UserBase += "`n`nFiles the client attached (names only, data):`n" + (New-BKDataFence -Tag "client_inputs" -Text $InputsNote -Max 1200) }
    $User = $UserBase
    $Plan = $null

    for ($Attempt = 1; $Attempt -le $MaxAttempts; $Attempt++) {
        $Attempts = $Attempt
        $Call = Invoke-BKChloeLlm -Model $Phase.Model -System $System -User $User -Tool $Tool -MaxTokens 9000 -TimeoutSec 240 -Retries 1 -Effort $Phase.Effort
        $Totals = Add-BKUsageTotals -Total $Totals -Usage $Call.Usage
        if (-not $Call.Ok) {
            $Errors += "Appel ${Attempt} : $($Call.Error)"
            if ($Call.Error -eq "NO_KEY" -or $Call.Error -like "HTTP*") { $FallbackReason = $Call.Error; break }
            $User = $UserBase + "`n`nYour previous answer was not a valid tool call. Call submit_project_plan with a valid plan."
            continue
        }
        $Check = Test-BKProjectPlan -Raw $Call.Input -Allowed $Allowed -Roster $Roster -AllowedNow $AllowedNow -Cards $Cards -Goal $Goal -Language $(if ($Language) { $Language } else { "fr" })
        $Warnings = @($Check.Warnings)
        if ($Check.Ok) {
            $Plan = $Check.Plan
            $Plan["source"] = "model"
            $Plan["model"] = $Phase.Model
            break
        }
        $Errors += @($Check.Errors | ForEach-Object { "Appel ${Attempt} : $_" })
        $User = $UserBase + "`n`nYour previous plan was rejected by the validator for these reasons:`n- " + ((@($Check.Errors) | Select-Object -First 12) -join "`n- ") + "`nFix them and call submit_project_plan again with the complete corrected plan."
    }

    if ($null -ne $Plan) {
        # Offre d'embauche : decidee par le CODE a partir de la portee (jamais par le modele) pour les parties que le client n'a pas.
        $DeniedIds = @($Denied | ForEach-Object { [string](Get-BKProp $_ "workerId" "") })
        $Plan.delegation.hireOffer = @($Plan.unassignable | ForEach-Object { $_.bestWorker } | Where-Object { $_ -and ($DeniedIds -contains $_) } | Select-Object -Unique)
        return @{ Ok = $true; Source = "model"; Plan = $Plan; Errors = $Errors; Warnings = $Warnings; Usage = $Totals; Attempts = $Attempts; Model = $Phase.Model; FallbackReason = "" }
    }

    # ---- repli : ancien routage (IA puis mots-cles) et plan minimal, sans appeler le modele fort une troisieme fois
    if (-not $FallbackReason) { $FallbackReason = "INVALID_PLAN" }
    $Ids = @()
    $Source = "keywords"
    if (Get-Command Invoke-BKChloeAIRouting -ErrorAction SilentlyContinue) {
        try {
            $Excluded = @($RoutingConfig.excluded_from_routing)
            $Hired = if ($Allowed.Count -lt $Roster.Count) { $Allowed } else { $null }        # equipe complete : aucune preference a donner a l'ancien routeur
            $Ai = Invoke-BKChloeAIRouting -UserRequest $Goal -RoutingConfig $RoutingConfig -Excluded $Excluded -PreferredIds $Hired
            if ($null -ne $Ai -and @($Ai.Workers).Count -gt 0) { $Ids = @($Ai.Workers | ForEach-Object { ([string]$_).ToLowerInvariant() }); $Source = "legacy-ai" }
        } catch { }
    }
    if ($Ids.Count -eq 0 -and (Get-Command Get-BKChloeKeywordWorkers -ErrorAction SilentlyContinue)) { $Ids = @(Get-BKChloeKeywordWorkers -Request $Goal -RoutingConfig $RoutingConfig -FoldAccents) }
    $Fallback = New-BKFallbackProjectPlan -Goal $Goal -WorkerIds $Ids -Allowed $Allowed -Cards $Cards -Denied $Denied -Language $(if ($Language) { $Language } else { "fr" }) -Chain:$Chain -Source $Source
    if ($null -eq $Fallback) {
        return @{ Ok = $false; Source = "none"; Plan = $null; Errors = $Errors + "NO_WORKER_IN_SCOPE"; Warnings = $Warnings; Usage = $Totals; Attempts = $Attempts; Model = $Phase.Model; FallbackReason = $FallbackReason }
    }
    $Fallback["source"] = "fallback"
    return @{ Ok = $true; Source = "fallback"; Plan = $Fallback; Errors = $Errors; Warnings = $Warnings; Usage = $Totals; Attempts = $Attempts; Model = $Phase.Model; FallbackReason = $FallbackReason }
}
