# =====================================================================
# BK-AI-WORKERS — Dashboard : pont CLI vers AUTOMATION-ENGINE.ps1
# Appele par dashboard/server.py (POST/GET /api/automations*). Ecrit
# le resultat JSON dans -OutFile (meme convention que Submit-Task.ps1).
# =====================================================================

param(
    [Parameter(Mandatory=$true)][ValidateSet("list","create","delete","toggle","tick","runs","run")][string]$Action,
    [string]$Id = "",
    [string]$WorkerId = "",
    [string]$Objective = "",
    [int]$FrequencyMinutes = 0,
    [string]$Enabled = "1",
    [string]$NotifySlack = "0",
    [string]$ClientId = "",
    [Parameter(Mandatory=$true)][string]$OutFile
)

# [bool] en parametre CLI via -File ne convertit pas de facon fiable une
# chaine "1"/"0" recue depuis powershell.exe -File (teste et reproduit :
# echoue meme avec "-Enabled 1" litteral) -> on recoit une chaine et on
# l'interprete nous-memes.
$EnabledBool = $Enabled -in @("1", "true", "True", "$true")
$NotifySlackBool = $NotifySlack -in @("1", "true", "True", "$true")

$ErrorActionPreference = "Stop"
# PowerShell 7+ : ne pas convertir les dates ISO en [datetime] (Windows PowerShell 5.1 les laissait en texte ; le moteur compare/hashe ces textes).
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String" }
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/automation/AUTOMATION-ENGINE.ps1")

$ListActions = @("list", "toggle", "tick", "runs")

$Result = switch ($Action) {
    "list"   { @(Get-Automations -ClientId $ClientId) }
    "create" { New-Automation -WorkerId $WorkerId -Objective $Objective -FrequencyMinutes $FrequencyMinutes -Enabled $EnabledBool -NotifySlack $NotifySlackBool -ClientId $(if ($ClientId) { $ClientId } else { "CLI-DASHBOARD" }) }
    "delete" { $Deleted = Remove-AutomationById -Id $Id -ClientId $ClientId; @{ deleted = $(if ($Deleted) { $Id } else { $null }) } }
    "toggle" { Set-AutomationEnabled -Id $Id -Enabled $EnabledBool -ClientId $ClientId; @(Get-Automations -ClientId $ClientId | Where-Object { $_.id -eq $Id }) }
    "tick"   { @(Invoke-AutomationTick -ClientId $ClientId) }
    "runs"   { @(Get-AutomationRuns -Id $Id -ClientId $ClientId) }
    "run"    {
        # "Executer maintenant" doit FORCER l'execution tout de suite,
        # peu importe l'echeance — avant ce correctif, le bouton passait
        # par "tick", qui n'execute que les automatisations deja dues :
        # une automatisation qui venait de tourner (via le cron ajoute
        # le 2026-09-24) redevenait due seulement le lendemain, et un
        # clic sur "Executer maintenant" ne faisait alors rigoureusement
        # rien, sans le moindre message d'erreur (signale par Kader en
        # conditions reelles). Meme controle de proprietaire que
        # Get-AutomationRuns : un client ne doit jamais pouvoir forcer
        # l'automatisation d'un autre en devinant son id.
        $Target = @(Get-Automations -ClientId $ClientId) | Where-Object { $_.id -eq $Id } | Select-Object -First 1
        if (-not $Target) {
            @{ error = "NOT_FOUND" }
        } else {
            $RunResult = Invoke-AutomationRun -Automation $Target
            @{ automationId = $Id; status = $RunResult.status }
        }
    }
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
