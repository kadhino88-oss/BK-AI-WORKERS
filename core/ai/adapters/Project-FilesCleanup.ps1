# =====================================================================
# BK-AI-WORKERS - Nettoyage des fichiers orphelins chez le fournisseur d'IA (API Files) : docs/AUTONOMY-ENGINE.md, section 3.9.
#
#   pwsh -NoProfile -File core/ai/adapters/Project-FilesCleanup.ps1 -IdsFile <fichier.json>     ({"ids": ["file_...", ...]})
#
# Appele par dashboard/projects_housekeeping.py (toutes les 30 minutes et au demarrage) pour les fichiers d'etapes interrompues : le lanceur d'etape
# supprime les siens a la fin de l'etape, mais un plantage entre l'envoi et le nettoyage les laisse chez le fournisseur. La cle API est lue ICI,
# en memoire (Get-BKSecretValue) : Python ne la voit jamais. Aucune sortie ne contient la cle.
# Codes de sortie : 0 = tous les identifiants sont supprimes ou deja absents ; 10 = entree invalide ; 11 = cle non configuree ; 12 = au moins un echec.
# =====================================================================
param([Parameter(Mandatory = $true)][string]$IdsFile)

$ErrorActionPreference = "Stop"
$ProjectRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { (Resolve-Path (Join-Path $PSScriptRoot "../../..")).Path }
. (Join-Path $ProjectRoot "core/ai/BK-Secret.ps1")

$Ids = @()
try {
    $Data = Get-Content -LiteralPath $IdsFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $Ids = @($Data.ids | Where-Object { [string]$_ -match '^file_[A-Za-z0-9_-]{6,80}$' } | Select-Object -Unique -First 200)
}
catch { Write-Host "Project-FilesCleanup : entree invalide"; exit 10 }
if ($Ids.Count -eq 0) { Write-Host "Project-FilesCleanup : rien a supprimer"; exit 0 }
if (-not (Test-BKSecret -Name "anthropic")) { Write-Host "Project-FilesCleanup : cle API non configuree"; exit 11 }

$Key = Get-BKSecretValue -Name "anthropic"
$Failed = 0; $Deleted = 0
foreach ($Id in $Ids) {
    try {
        Invoke-RestMethod -Uri "https://api.anthropic.com/v1/files/$Id" -Method Delete -Headers @{ "x-api-key" = $Key; "anthropic-version" = "2023-06-01" } -TimeoutSec 30 | Out-Null
        $Deleted++
    }
    catch {
        $Status = 0
        try { $Status = [int]$_.Exception.Response.StatusCode } catch { }
        if ($Status -eq 404) { $Deleted++ } else { $Failed++ }        # deja supprime : c'est le resultat voulu
    }
}
$Key = $null
Write-Host "Project-FilesCleanup : $Deleted supprime(s), $Failed echec(s)"
exit $(if ($Failed -gt 0) { 12 } else { 0 })
