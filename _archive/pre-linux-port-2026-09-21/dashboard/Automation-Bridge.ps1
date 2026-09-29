# =====================================================================
# BK-AI-WORKERS — Dashboard : pont CLI vers AUTOMATION-ENGINE.ps1
# Appele par dashboard/server.py (POST/GET /api/automations*). Ecrit
# le resultat JSON dans -OutFile (meme convention que Submit-Task.ps1).
# =====================================================================

param(
    [Parameter(Mandatory=$true)][ValidateSet("list","create","delete","toggle","tick","runs")][string]$Action,
    [string]$Id = "",
    [string]$WorkerId = "",
    [string]$Objective = "",
    [int]$FrequencyMinutes = 0,
    [string]$Enabled = "1",
    [string]$NotifySlack = "0",
    [Parameter(Mandatory=$true)][string]$OutFile
)

# [bool] en parametre CLI via -File ne convertit pas de facon fiable une
# chaine "1"/"0" recue depuis powershell.exe -File (teste et reproduit :
# echoue meme avec "-Enabled 1" litteral) -> on recoit une chaine et on
# l'interprete nous-memes.
$EnabledBool = $Enabled -in @("1", "true", "True", "$true")
$NotifySlackBool = $NotifySlack -in @("1", "true", "True", "$true")

$ErrorActionPreference = "Stop"
$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
. (Join-Path $Root "core\automation\AUTOMATION-ENGINE.ps1")

$ListActions = @("list", "toggle", "tick", "runs")

$Result = switch ($Action) {
    "list"   { @(Get-Automations) }
    "create" { New-Automation -WorkerId $WorkerId -Objective $Objective -FrequencyMinutes $FrequencyMinutes -Enabled $EnabledBool -NotifySlack $NotifySlackBool }
    "delete" { Remove-AutomationById -Id $Id; @{ deleted = $Id } }
    "toggle" { Set-AutomationEnabled -Id $Id -Enabled $EnabledBool; @(Get-Automations | Where-Object { $_.id -eq $Id }) }
    "tick"   { @(Invoke-AutomationTick) }
    "runs"   { @(Get-AutomationRuns -Id $Id) }
}

# ConvertTo-Json "deballe" un tableau d'un seul element (comportement
# PowerShell 5.1 connu) : on force explicitement le format tableau pour
# les actions qui renvoient conceptuellement une liste, meme a 0 ou 1
# element, pour que le front-end (qui attend toujours un array) ne casse pas.
if ($Action -in $ListActions) {
    $Count = @($Result).Count
    if ($Count -eq 0) {
        $Json = "[]"
    }
    elseif ($Count -eq 1) {
        $Json = "[" + (@($Result)[0] | ConvertTo-Json -Depth 20) + "]"
    }
    else {
        $Json = $Result | ConvertTo-Json -Depth 20
    }
}
else {
    $Json = $Result | ConvertTo-Json -Depth 20
}

[System.IO.File]::WriteAllText(
    $OutFile,
    $Json,
    [System.Text.UTF8Encoding]::new($false)
)
