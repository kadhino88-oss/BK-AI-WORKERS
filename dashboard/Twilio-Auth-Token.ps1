# =====================================================================
# BK-AI-WORKERS — Standard telephonique (2026-10-06) : fournit a
# dashboard/phone_agent.py l'Auth Token Twilio d'un client, deja
# dechiffre, pour verifier la signature des appels entrants.
#
# Le dechiffrement des identifiants clients reste ICI, en PowerShell
# (Client-Credential-Store.ps1) ; Python garde le jeton en memoire seulement
# (10 min), jamais sur disque ni dans les journaux. Le jeton sort sur la sortie
# standard (tube vers le processus parent) : aucun fichier temporaire.
# Codes de sortie : 0 = jeton ecrit ; 3 = aucun identifiant Twilio ; 4 = erreur.
# =====================================================================

param(
    [Parameter(Mandatory=$true)][string]$ClientId
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/connectors/Client-Credential-Store.ps1")

try {
    $SafeClientId = $ClientId -replace '[^a-zA-Z0-9_-]', ''
    $Raw = Get-BKClientCredentialValue -ClientId $SafeClientId -Provider "twilio"
    if (-not $Raw) { exit 3 }
    $Token = [string](($Raw | ConvertFrom-Json).pass)
    if (-not $Token) { exit 3 }
    [Console]::Out.Write($Token)
    exit 0
} catch {
    exit 4
}
