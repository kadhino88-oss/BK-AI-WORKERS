# =====================================================================
# CHLOE - consolidation (2026-10-19) : qui a fait quoi, avec les fichiers et les actions a valider, par Worker.
#
# Deterministe, sans appel au modele : le texte de Chloe ne depend que de ce que le CODE sait (le plan fixe avant l'execution, l'etat de chaque
# sous-tache, les fichiers et actions renvoyes par les Workers). Une reponse de Worker ne peut donc pas faire dire a Chloe autre chose que
# « ce Worker a repondu ceci » : elle n'est jamais interpretee.
#
# Sortie : @{ Sections; Overview; FinalSynthesis; Failures; Deferred; Pending; OverallStatus }
#   Sections       une entree par sous-tache (Worker, statut, ce qui lui etait demande, reponse, fichiers) : l'interface les affiche par Worker
#   Overview       le resume de Chloe SANS les reponses (qui a fait quoi, fichiers, a valider, non realise, a harmoniser, notes)
#   FinalSynthesis le texte complet (Overview + reponses) pour tous les consommateurs de texte (WhatsApp, memoire, API)
# =====================================================================

function Get-BKChloeStatusLabel {
    param([string]$Status, $L)
    switch ($Status) {
        "DONE"      { return $L.Done }
        "FAILED"    { return $L.Failed }
        "BLOCKED"   { return $L.Blocked }
        "DEFERRED"  { return $L.Deferred }
        "TIMED_OUT" { return $L.TimedOut }
        default     { return $Status }
    }
}

function Join-BKChloeNames {
    param([string[]]$Names, [string]$Lang = "fr")
    $N = @($Names | Where-Object { $_ })
    if ($N.Count -le 1) { return ($N -join "") }
    $And = if ($Lang -eq "fr") { " et " } else { " and " }
    return (($N | Select-Object -First ($N.Count - 1)) -join ", ") + $And + $N[-1]
}

function Get-BKChloeFailureReason {
    param($Task, $L)
    switch ([string]$Task.reason) {
        "TIME"              { return $(if ($Task.status -eq "TIMED_OUT") { "délai dépassé" } else { "temps imparti écoulé" }) }
        "QUOTA"             { return "crédits insuffisants" }
        "BUSY"              { return "serveur très sollicité" }
        "DEPENDENCY_FAILED" { return "un résultat dont il dépendait manque" }
        "DEGRADED"          { return "le fournisseur d'IA était indisponible" }
        "REVIEW"            { return ([string]$Task.reviewNote -replace ' — .*$', '') }
        default             { return $(if ($Task.error) { Limit-BKText -Text ([string]$Task.error) -Max 120 } else { "erreur" }) }
    }
}

function New-BKChloeConsolidation {
    param(
        $Ctx,
        $Plan,
        [array]$NotIncluded = @(),       # sous-taches du plan dont le Worker n'est pas embauche : @{ worker; displayName; objective }
        [array]$QuotaSkipped = @(),      # sous-taches non lancees faute de credits (avant le debut) : meme forme
        [string]$ResetNote = "",         # « demain a 08:00 » : moment ou les credits reviennent (quand le serveur le sait)
        [bool]$ProjectsEnabled = $false, # projets actives : la partie non traitee faute de credits peut etre proposee comme projet (qui attend les credits)
        $Consistency = $null,
        $L,
        [string]$Lang = "fr"
    )
    $Ordered = @($Ctx.Order | ForEach-Object { $Ctx.Tasks[$_] })
    $Ran = @($Ordered | Where-Object { $_.attempts -gt 0 })
    $Done = @($Ordered | Where-Object { $_.status -eq "DONE" })
    $Sections = @()
    foreach ($T in $Ordered) {
        $Files = @()
        foreach ($F in @($T.files)) {
            $Files += [ordered]@{ filename = [string](Get-BKProp $F "filename" ""); sizeBytes = (Get-BKProp $F "sizeBytes" 0); mime = [string](Get-BKProp $F "mime" ""); taskId = $T.taskId }
        }
        $Sections += [ordered]@{
            step = $T.id; worker = $T.worker; workerName = $T.displayName; status = $T.status; statusLabel = (Get-BKChloeStatusLabel -Status $T.status -L $L)
            objective = $T.objective; why = $T.why; dependsOn = @($T.dependsOn); taskId = $T.taskId; durationSec = [int]$T.durationSec
            answer = $(if ($T.status -eq "DONE" -or ($T.degraded -and $T.answer)) { [string]$T.answer } else { $null })
            degraded = [bool]$T.degraded
            note = $(if ($T.status -eq "DONE") { "" } else { Get-BKChloeFailureReason -Task $T -L $L })
            files = @($Files)
        }
    }

    # ---- parties de l'apercu
    $Names = @($Ran | ForEach-Object { $_.displayName })
    $Intro = ""
    if ($Ordered.Count -gt 1) { $Intro = ($L.Intro -f $Ordered.Count, (Join-BKChloeNames -Names @($Ordered | ForEach-Object { $_.displayName }) -Lang $Lang)) }
    $FileLines = @()
    foreach ($T in $Done) { foreach ($F in @($T.files)) { $N = [string](Get-BKProp $F "filename" ""); if ($N) { $FileLines += "$N ($($T.displayName))" } } }
    $ToValidate = @()
    foreach ($T in $Done) {
        foreach ($A in @(Get-BKProp $T.result "connector_actions" @() | Where-Object { $null -ne $_ -and [string](Get-BKProp $_ "status" "") -eq "PENDING_CONFIRMATION" })) {
            $ToValidate += ($L.ToValidateItem -f $T.displayName, [string](Get-BKProp $A "connectorId" ""), [string](Get-BKProp $A "operation" ""))
        }
    }
    $NotDone = @()
    foreach ($T in $Ordered) {
        if ($T.status -eq "DONE") { continue }
        if ($T.status -eq "BLOCKED") {
            $By = if ($T.blockedBy -and $Ctx.Tasks[$T.blockedBy]) { $Ctx.Tasks[$T.blockedBy].displayName } else { "?" }
            $NotDone += ($L.DependencyNote -f $T.displayName, $By)
        }
        elseif ($T.status -eq "FAILED" -or $T.status -eq "TIMED_OUT") { $NotDone += ($L.FailedNote -f $T.displayName, (Get-BKChloeFailureReason -Task $T -L $L)) }
    }
    $Deferred = @($Ordered | Where-Object { $_.status -eq "DEFERRED" })
    $Failures = @($Ordered | Where-Object { $_.status -in @("FAILED", "TIMED_OUT", "BLOCKED") } | ForEach-Object { [ordered]@{ step = $_.id; worker = $_.worker; status = $_.status; reason = $_.reason; detail = (Get-BKChloeFailureReason -Task $_ -L $L) } })
    $Notes = @()
    $TimeDeferred = @($Deferred | Where-Object { $_.reason -eq "TIME" -or $_.reason -eq "BUSY" })
    $QuotaDeferred = @($Deferred | Where-Object { $_.reason -eq "QUOTA" })
    if ($TimeDeferred.Count -gt 0) { $Notes += ($L.TimeNote -f (Join-BKChloeNames -Names @($TimeDeferred | ForEach-Object { $_.displayName }) -Lang $Lang)) }
    $AllQuota = @($QuotaSkipped | ForEach-Object { $_.displayName }) + @($QuotaDeferred | ForEach-Object { $_.displayName })
    if ($AllQuota.Count -gt 0) {
        $Notes += $(if ($ResetNote) { $L.QuotaWindowNote -f ($AllQuota -join ", "), $ResetNote } else { $L.QuotaNote -f ($AllQuota -join ", ") })
        if ($ProjectsEnabled) { $Notes += $L.QuotaProjectHint }
    }
    if ($NotIncluded.Count -gt 0) {
        $Notes += ($L.NotIncluded -f ((@($NotIncluded | ForEach-Object { $_.displayName })) -join ", "))
        $Notes += ($L.HireOffer -f (Join-BKChloeNames -Names @($NotIncluded | ForEach-Object { $_.displayName }) -Lang $Lang))
    }
    $ConsistencyLines = @()
    if ($Consistency -and $Consistency.Ok) {
        foreach ($I in @($Consistency.Issues)) { $ConsistencyLines += [string]$I.text }
    }
    # Suite proposee pour ce qui n'a pas ete fait : un message pret a envoyer, redige a partir du plan (jamais d'une reponse de Worker)
    $Left = @($Ordered | Where-Object { $_.status -in @("DEFERRED", "BLOCKED", "FAILED", "TIMED_OUT") }) + @($QuotaSkipped | ForEach-Object { [pscustomobject]$_ })
    $ContinuePrompt = ""
    if ($Left.Count -gt 0 -and $Done.Count -gt 0) {
        $Parts = @($Left | ForEach-Object { "$($_.displayName) : $(Limit-BKText -Text ([string]$_.objective) -Max 160)" })
        $ContinuePrompt = (Limit-BKText -Text ($Parts -join " — ") -Max 600)
    }

    # ---- apercu (sans les reponses)
    $OverviewLines = @()
    if ($Intro) { $OverviewLines += "**$Intro**" }
    if ($FileLines.Count -gt 0) { $OverviewLines += "**$($L.Files) :** " + ($FileLines -join " ; ") }
    if ($ToValidate.Count -gt 0) { $OverviewLines += "**$($L.ToValidate) :**`n" + (($ToValidate | ForEach-Object { "- $_" }) -join "`n") }
    if ($NotDone.Count -gt 0) { $OverviewLines += "**$($L.NotDone) :**`n" + (($NotDone | ForEach-Object { "- $_" }) -join "`n") }
    if ($ConsistencyLines.Count -gt 0) { $OverviewLines += "**$($L.Consistency) :**`n" + (($ConsistencyLines | ForEach-Object { "- $_" }) -join "`n") }
    foreach ($N in $Notes) { $OverviewLines += $N }
    if ($ContinuePrompt) { $OverviewLines += ($L.Continue -f $ContinuePrompt) }
    $Overview = ($OverviewLines -join "`n`n").Trim()

    # ---- texte complet
    $Parts = @()
    if ($Intro) { $Parts += "**$Intro**" }
    $Answered = @($Sections | Where-Object { $_.answer })
    if ($Answered.Count -eq 1 -and $Ordered.Count -eq 1) {
        $Parts += [string]$Answered[0].answer      # un seul Worker : sa reponse telle quelle (comme avant), sans en-tete
    }
    else {
        foreach ($S in $Answered) {
            # Plan sans decoupage (chaque Worker a recu la demande telle quelle) : l'en-tete ne la repete pas, il nomme seulement le Worker.
            $Asked = if ([string]$S.objective -eq [string]$Ctx.Request) { "" } else { " — " + (Limit-BKText -Text ([string]$S.objective) -Max 90) }
            $Parts += "### $($S.workerName)" + $Asked + $(if ($S.degraded) { " (réponse de secours)" } else { "" }) + "`n`n" + [string]$S.answer
        }
    }
    $Tail = @($OverviewLines | Where-Object { $_ -ne ("**$Intro**") })
    if ($Tail.Count -gt 0) { $Parts += ($Tail -join "`n`n") }
    $Final = ($Parts -join "`n`n").Trim()
    if (-not $Final) { $Final = $L.NoResult }

    # ---- statut global : comme avant (SUCCESS / PARTIAL_SUCCESS / BLOCKED), calcule sur les sous-taches du plan retenues
    $Overall = if ($Ordered.Count -gt 0 -and $Done.Count -eq $Ordered.Count) { "SUCCESS" } elseif ($Done.Count -gt 0) { "PARTIAL_SUCCESS" } else { "BLOCKED" }
    return @{
        Sections = @($Sections); Overview = $Overview; FinalSynthesis = $Final; Failures = @($Failures)
        Deferred = @($Deferred | ForEach-Object { [ordered]@{ step = $_.id; worker = $_.worker; reason = $_.reason } })
        ToValidate = @($ToValidate); OverallStatus = $Overall; ContinuePrompt = $ContinuePrompt
    }
}
