# Rejeu HORS LIGNE du jeu de demandes etiquetees avec la cassette enregistree par record_routing.ps1 : aucune API, aucun cout.
# Variables : REPO (racine du depot), CASES_FILE, CASSETTE_FILE, OUT_FILE.
$ErrorActionPreference = "Stop"
$Repo = $env:REPO
$env:BK_ROOT = $Repo
$env:BK_SECRET_ANTHROPIC = "FAKE-KEY-FOR-REPLAY"
. (Join-Path $Repo "core/ai/BK-Secret.ps1")
foreach ($H in @("Chloe-Common.ps1", "Chloe-LegacyRouting.ps1", "Chloe-Router.ps1")) { . (Join-Path $Repo "chloe/$H") }
. (Join-Path $Repo "tests/chloe-delegation/routing_harness.ps1")

$Cassette = Get-Content -LiteralPath $env:CASSETTE_FILE -Raw -Encoding UTF8 | ConvertFrom-Json
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $ContentType, $Body, $TimeoutSec)
    $Key = Get-BKRequestKey -BodyBytes $Body
    $Entry = $Cassette.entries.PSObject.Properties[$Key]
    if ($null -eq $Entry) { throw "NO_RECORDED_RESPONSE for $Key" }
    return $Entry.Value
}

$Routing = Get-Content -LiteralPath (Join-Path $Repo "orchestrator/worker-routing.json") -Raw -Encoding UTF8 | ConvertFrom-Json
$Cards = Get-BKChloeCards -Root $Repo -RoutingConfig $Routing
$Cases = (Get-Content -LiteralPath $env:CASES_FILE -Raw -Encoding UTF8 | ConvertFrom-Json).cases
$Out = @()
foreach ($C in $Cases) { $Out += Get-BKRoutingPrediction -Case $C -Root $Repo -RoutingConfig $Routing -Cards $Cards -LegacyModel ([string]$Cassette.meta.model) }

# Empreintes : la cassette n'est valable que pour CE prompt du routeur et CES mots-cles (sinon : relancer record_routing.ps1)
$env:BK_REPLY_LANG = ""
$Roster = @(Get-BKChloeRosterIds -RoutingConfig $Routing)
$PromptSha = Get-BKSha256Hex -Text (Get-BKChloeRouteSystemPrompt -Cards $Cards -RosterIds $Roster -Allowed $null -ProjectsEnabled $false -Lang "fr")
$RoutingSha = Get-BKSha256Hex -Text (($Routing.workers.PSObject.Properties | ForEach-Object { $_.Name + ":" + (@($_.Value.primary) -join "|") }) -join ";")
ConvertTo-Json -InputObject ([ordered]@{ promptSha = $PromptSha; routingSha = $RoutingSha; predictions = @($Out) }) -Depth 10 | Set-Content -LiteralPath $env:OUT_FILE -Encoding utf8
