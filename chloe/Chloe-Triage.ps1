# =====================================================================
# CHLOE - aiguillage « mission ou projet ? » (2026-10-19, docs/AUTONOMY-ENGINE.md section 6c.1). Appele par POST /api/chloe/triage (BK_PROJECTS=1).
#
# Un seul appel peu couteux (Haiku 5.5, SANS credit pour le client, 20 par heure) : le routeur de Chloe lit la demande, la decoupe et juge si c'est une
# reponse rapide (mode mission) ou un travail de plusieurs etapes et de plusieurs Workers (mode projet). Aucun Worker n'est lance, rien n'est execute :
# le client confirme toujours (« Lancer comme projet » ou « juste une reponse rapide »).
#
# Sortie (JSON dans -OutFile) : { ok, mode, why, source, workers:[{id,name,objective,included}], notIncluded:[ids], estimate:{missionCredits,projectCredits:[min,max]} }
# Les droits viennent de BK_ALLOWED_WORKERS (pose par le serveur), jamais du modele. Repli sans modele : mots-cles, toujours en mode mission.
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Request,
    [Parameter(Mandatory=$true)][string]$OutFile
)
$ErrorActionPreference = "Stop"
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $Root "core/ai/BK-Secret.ps1")
foreach ($Helper in @("Chloe-Common.ps1", "Chloe-Router.ps1")) { . (Join-Path $PSScriptRoot $Helper) }

function Write-Out($Object) { [System.IO.File]::WriteAllText($OutFile, ($Object | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false)) }

try {
    $Routing = Get-Content -LiteralPath (Join-Path $Root "orchestrator/worker-routing.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    $Allowed = Get-BKChloeAllowedWorkers
    $Cards = Get-BKChloeCards -Root $Root -RoutingConfig $Routing
    $Lang = Get-BKChloeReplyLang -Request $Request
    $Plan = $null
    $Route = Invoke-BKChloeRoute -Request $Request -RoutingConfig $Routing -Root $Root -Cards $Cards -Allowed $Allowed -ProjectsEnabled $true -Lang $Lang
    if ($Route.Plan) { $Plan = $Route.Plan }
    $Source = if ($Plan) { "model" } else { "keywords" }
    if ($null -eq $Plan) {
        $Ids = @(Get-BKChloeKeywordWorkers -Request $Request -RoutingConfig $Routing)
        $Plan = if ($Ids.Count -gt 0) { New-BKChloeSimplePlan -Request $Request -WorkerIds $Ids -Source "keywords" } else { [ordered]@{ mode = "direct_reply"; why = ""; subtasks = @() } }
    }
    $Level = if ($env:BK_MISSION_LEVEL -match '^[a-z]{3,20}$') { [string]$env:BK_MISSION_LEVEL } else { "" }
    $LevelCredits = 1
    try {
        if ($Level) { $Lv = (Get-Content -LiteralPath (Join-Path $Root "core/ai/LEVELS.json") -Raw -Encoding UTF8 | ConvertFrom-Json).levels.PSObject.Properties[$Level]; if ($Lv -and [int]$Lv.Value.credits -gt 0) { $LevelCredits = [int]$Lv.Value.credits } }
    } catch { }
    $Workers = @()
    $Min = 0; $Max = 0
    foreach ($T in @($Plan.subtasks)) {
        $Included = ($null -eq $Allowed) -or ($Allowed -contains [string]$T.worker)
        $Card = if ($Cards.ContainsKey([string]$T.worker)) { $Cards[[string]$T.worker] } else { $null }
        $Workers += [ordered]@{ id = [string]$T.worker; name = (Get-BKWorkerDisplayName -Cards $Cards -Id ([string]$T.worker)); objective = [string]$T.objective; included = [bool]$Included }
        if ($Included -and $Card -and @($Card.typicalStepCredits).Count -ge 2) { $Min += [int]$Card.typicalStepCredits[0]; $Max += 2 * [int]$Card.typicalStepCredits[1] }
    }
    $Mode = [string]$Plan.mode
    if ($Mode -eq "mission" -and @($Workers).Count -eq 0) { $Mode = "direct_reply" }
    Write-Out ([ordered]@{
        ok = $true; mode = $Mode; why = [string]$Plan.why; source = $Source; language = $Lang
        directReply = $(if ($Mode -eq "direct_reply") { [string](Get-BKProp $Plan "directReply" "") } else { $null })
        workers = @($Workers); notIncluded = @($Workers | Where-Object { -not $_.included } | ForEach-Object { $_.id })
        estimate = [ordered]@{ missionCredits = (@($Workers | Where-Object { $_.included }).Count * $LevelCredits); projectCredits = @($Min, $Max) }
    })
}
catch {
    Write-Out ([ordered]@{ ok = $false; error = [string]$_.Exception.Message })
}
