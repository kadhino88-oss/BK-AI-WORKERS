# ENREGISTREMENT REEL du jeu de demandes etiquetees : appelle VRAIMENT l'API Anthropic (cle du proprietaire, lue en memoire, jamais affichee) avec
# l'ancien routeur (mots-cles + repli IA) et le nouveau routeur (plan de sous-taches), et ecrit la cassette rejouee hors ligne par
# test_routing_accuracy.py. A lancer UNE FOIS, sous Windows (cle DPAPI), apres accord du proprietaire pour la depense :
#
#   pwsh -NoProfile -File tests/chloe-delegation/record_routing.ps1 -Out tests/chloe-delegation/routing_cassette.json [-Model claude-haiku-5-5] [-CapUsd 1.5]
#
# S'arrete au premier refus de l'API (cle ou schema invalides : rien n'est depense de plus) et des que le cout estime depasse le plafond. Le cout de
# CHAQUE appel est comptabilise (core/ai/adapters/Mission-Cost.ps1, tarifs core/ai/AI-PRICING.json) et ecrit dans la cassette.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Out,
    [string]$Model = "claude-haiku-5-5",
    [double]$CapUsd = 1.5,
    [string]$SecretsRoot = ""            # dossier qui contient .secrets (le depot principal : un worktree n'a pas de .secrets)
)
$ErrorActionPreference = "Stop"
$Repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($SecretsRoot)) { $SecretsRoot = $Repo }
$env:BK_ROOT = $SecretsRoot                                           # lecture de la cle (BK-Secret.ps1) et des tarifs
. (Join-Path $Repo "core/ai/BK-Secret.ps1")
if (-not (Test-BKSecret -Name "anthropic")) { throw "Aucune cle Anthropic trouvee (DPAPI) dans $SecretsRoot : arret, rien n'a ete depense." }
. (Join-Path $Repo "core/ai/adapters/Mission-Cost.ps1")
foreach ($H in @("Chloe-Common.ps1", "Chloe-LegacyRouting.ps1", "Chloe-Router.ps1")) { . (Join-Path $Repo "chloe/$H") }
. (Join-Path $Repo "tests/chloe-delegation/routing_harness.ps1")

$Script:Entries = [ordered]@{}
$Script:Cost = New-BKMissionCost -Pricing (Get-BKPricing -Root $Repo) -Model $Model
$Script:Calls = 0
function Invoke-RestMethod {
    param($Uri, $Method = "GET", $Headers, $ContentType, $Body, $TimeoutSec)
    if ($Script:Cost.Usd -gt $CapUsd) { throw "PLAFOND DE DEPENSE ATTEINT ($($Script:Cost.Usd) USD > $CapUsd) : arret." }
    $Key = Get-BKRequestKey -BodyBytes $Body
    $Resp = Microsoft.PowerShell.Utility\Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -Body $Body -TimeoutSec $TimeoutSec
    $Script:Calls++
    Add-BKCallCost -Cost $Script:Cost -Response $Resp
    $Script:Entries[$Key] = $Resp
    return $Resp
}

$Routing = Get-Content -LiteralPath (Join-Path $Repo "orchestrator/worker-routing.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$Cards = Get-BKChloeCards -Root $Repo -RoutingConfig $Routing
$Cases = (Get-Content -LiteralPath (Join-Path $PSScriptRoot "routing_cases.json") -Raw -Encoding UTF8 | ConvertFrom-Json).cases
$env:BK_CHLOE_ROUTER_MODEL = $Model
$Done = 0
foreach ($C in $Cases) {
    $P = Get-BKRoutingPrediction -Case $C -Root $Repo -RoutingConfig $Routing -Cards $Cards -LegacyModel $Model
    $Done++
    Write-Host ("[{0}/{1}] {2,-16} new={3} | old={4} ({5}) | cumul {6:N4} USD" -f $Done, $Cases.Count, $C.id, (@($P.new.workers) -join ","), (@($P.old.workers) -join ","), $P.old.via, $Script:Cost.Usd)
    if ($P.new.source -eq "none" -and $Done -le 2 -and ($P.new.errors -join " ") -match "HTTP 4") { throw "Le nouveau routeur est refuse par l'API des la premiere demande : arret ($($P.new.errors -join '; '))" }
}
$Roster = @(Get-BKChloeRosterIds -RoutingConfig $Routing)
$env:BK_REPLY_LANG = ""
$PromptSha = Get-BKSha256Hex -Text (Get-BKChloeRouteSystemPrompt -Cards $Cards -RosterIds $Roster -Allowed $null -ProjectsEnabled $false -Lang "fr")
$RoutingSha = Get-BKSha256Hex -Text (($Routing.workers.PSObject.Properties | ForEach-Object { $_.Name + ":" + (@($_.Value.primary) -join "|") }) -join ";")
$Doc = [ordered]@{
    meta = [ordered]@{
        schema = "BK-ROUTING-CASSETTE-V1"; recordedUtc = (Get-Date).ToUniversalTime().ToString("o"); model = $Model; cases = $Cases.Count
        promptSha = $PromptSha; routingSha = $RoutingSha
        apiCalls = $Script:Calls; inputTokens = [long]$Script:Cost.InputTokens; outputTokens = [long]$Script:Cost.OutputTokens
        estimatedCostUsd = [Math]::Round([double]$Script:Cost.Usd, 6); capUsd = $CapUsd
    }
    entries = $Script:Entries
}
[System.IO.File]::WriteAllText($Out, ($Doc | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
Write-Host ("Cassette ecrite : {0} appels, {1} jetons en entree, {2} en sortie, cout estime {3:N4} USD (plafond {4})." -f $Script:Calls, $Script:Cost.InputTokens, $Script:Cost.OutputTokens, $Script:Cost.Usd, $CapUsd)
