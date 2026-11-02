# Banc d'essai du routage de Chloe : meme code pour l'enregistrement reel (record_routing.ps1, API Anthropic) et pour le rejeu hors ligne
# (replay_routing.ps1, cassette). Compare l'ANCIEN routage (mots-cles, puis repli IA qui renvoie des identifiants) au NOUVEAU (routeur a modele,
# plan de sous-taches). A dot-sourcer apres chloe/Chloe-Common.ps1, Chloe-LegacyRouting.ps1 et Chloe-Router.ps1.

function Get-BKSha256Hex {
    param([string]$Text)
    $Bytes = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($Text))
    return (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function Get-BKRequestKey {
    # Cle d'une requete a l'API : le dernier message du client (texte exact envoye au modele). Le nouveau routeur et l'ancien envoient des textes differents.
    param($BodyBytes)
    $Req = [System.Text.Encoding]::UTF8.GetString($BodyBytes) | ConvertFrom-Json
    $Last = @($Req.messages | Where-Object { $_.role -eq "user" }) | Select-Object -Last 1
    $Text = if ($Last.content -is [string]) { [string]$Last.content } else { (@($Last.content | ForEach-Object { [string]$_.text }) -join "`n") }
    return (Get-BKSha256Hex -Text $Text)
}

function Get-BKLangName {
    param([string]$Code)
    switch ($Code) { "fr" { "French" } "en" { "English" } "de" { "German" } "es" { "Spanish" } "it" { "Italian" } "pt" { "Portuguese" } default { "" } }
}

function Get-BKRoutingPrediction {
    # Predictions des deux routeurs pour UNE demande (aucun droit restreint : les 17 Workers).
    param($Case, [string]$Root, $RoutingConfig, $Cards, [string]$LegacyModel)
    $env:BK_REPLY_LANG = Get-BKLangName -Code ([string]$Case.lang)       # comme le serveur (detect_reply_language) : le routeur recoit la langue du client
    $Excluded = @($RoutingConfig.excluded_from_routing)
    $New = Invoke-BKChloeRoute -Request $Case.request -RoutingConfig $RoutingConfig -Root $Root -Cards $Cards -Allowed $null -ProjectsEnabled $false -Lang "fr"
    $NewMode = if ($New.Plan) { [string]$New.Plan.mode } else { "none" }
    $NewWorkers = @()
    if ($New.Plan -and $NewMode -ne "direct_reply") { $NewWorkers = @($New.Plan.subtasks | ForEach-Object { [string]$_.worker }) }
    $Edges = @()
    if ($New.Plan) { foreach ($T in @($New.Plan.subtasks)) { foreach ($D in @($T.dependsOn)) { $Edges += "$D->$($T.id)" } } }
    $Kw = @(Get-BKChloeKeywordWorkers -Request $Case.request -RoutingConfig $RoutingConfig)
    $Legacy = Invoke-BKChloeAIRouting -UserRequest $Case.request -RoutingConfig $RoutingConfig -Excluded $Excluded -PreferredIds $null -Model $LegacyModel
    $LegacyWorkers = if ($Legacy) { @($Legacy.Workers | ForEach-Object { ([string]$_).ToLowerInvariant() }) } else { @() }
    $LegacyDirect = ($Legacy -and -not [string]::IsNullOrWhiteSpace([string]$Legacy.DirectReply))
    # Ancien comportement de Chloe : les mots-cles d'abord ; le repli IA seulement quand aucun mot-cle ne correspond
    $OldVia = if ($Kw.Count -gt 0) { "keywords" } else { "ai" }
    $OldWorkers = if ($Kw.Count -gt 0) { $Kw } else { $LegacyWorkers }
    $OldDirect = ($Kw.Count -eq 0) -and $LegacyDirect
    $env:BK_REPLY_LANG = ""
    return [ordered]@{
        id = $Case.id
        new = [ordered]@{ mode = $NewMode; workers = @($NewWorkers); edges = @($Edges); source = $(if ($New.Plan) { "model" } else { "none" }); attempts = $New.Attempts; errors = @($New.Errors) }
        keywords = @($Kw)
        legacyAi = [ordered]@{ workers = @($LegacyWorkers); direct = [bool]$LegacyDirect; answered = [bool]($null -ne $Legacy) }
        old = [ordered]@{ via = $OldVia; workers = @($OldWorkers); direct = [bool]$OldDirect }
    }
}
