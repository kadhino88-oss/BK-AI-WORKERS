# =====================================================================
# CHLOE - appel d'UN Worker dans son propre processus (2026-10-19).
#
# Lance par chloe/Chloe-Executor.ps1 : chaque Worker d'une mission de Chloe tourne dans un processus PowerShell a part, ce qui permet (1) de les
# faire tourner en parallele sur le serveur (nombre borne), (2) de couper proprement un Worker qui depasse son delai sans perdre les autres,
# (3) de garder le MEME chemin d'autorisation reel a 14 etapes (Invoke-Worker-AI.ps1) que n'importe quel appel direct : aucun raccourci.
#
# Entree : un fichier JSON (les parametres de Invoke-Worker-AI.ps1, sans le jeton). Le jeton de session passe par la variable d'environnement
# BK_CHLOE_CALL_TOKEN (jamais sur la ligne de commande, jamais dans un fichier). Sortie : un fichier JSON { ok, result | error }.
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)
$ErrorActionPreference = "Stop"
# PowerShell 7+ : ne pas convertir les dates ISO en [datetime] (le moteur compare et hashe ces textes), comme dashboard/Submit-Task.ps1.
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String" }
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { Split-Path -Parent $PSScriptRoot }

function Write-Out($Object) {
    [System.IO.File]::WriteAllText($OutFile, ($Object | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
}

try {
    $In = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $Token = [string]$env:BK_CHLOE_CALL_TOKEN
    if ([string]::IsNullOrWhiteSpace($Token)) { throw "CALL_TOKEN_MISSING" }
    $env:BK_CHLOE_CALL_TOKEN = $null
    . (Join-Path $Root "core/ai/Get-DefaultProvider.ps1")
    $WorkerAIPath = Join-Path $Root "core/runtime/worker-runtime/Invoke-Worker-AI.ps1"
    $Json = & $WorkerAIPath `
        -WorkerId $In.WorkerId `
        -TaskId $In.TaskId `
        -Objective $In.Objective `
        -TenantId $In.TenantId `
        -ClientId $In.ClientId `
        -ProjectId $In.ProjectId `
        -ExecutionId $In.ExecutionId `
        -UserId $In.UserId `
        -SessionId $In.SessionId `
        -TokenId $In.TokenId `
        -Token $Token `
        -Environment $In.Environment `
        -Mode $In.Mode `
        -Provider (Get-DefaultAIProvider) `
        -Model "NONE" 2>&1
    $Token = $null
    $Parsed = $Json | ConvertFrom-Json -ErrorAction SilentlyContinue
    if ($null -eq $Parsed -and @($Json).Count -gt 1) { $Parsed = (@($Json) | Select-Object -Last 1) | ConvertFrom-Json -ErrorAction SilentlyContinue }   # sortie parasite : le JSON du Worker est la derniere ligne
    Write-Out ([ordered]@{ ok = ($null -ne $Parsed); result = $Parsed; error = $(if ($null -eq $Parsed) { "NO_RESULT" } else { $null }) })
}
catch {
    Write-Out ([ordered]@{ ok = $false; result = $null; error = [string]$_.Exception.Message })
}
