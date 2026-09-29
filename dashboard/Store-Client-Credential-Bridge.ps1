# =====================================================================
# BK-AI-WORKERS — Dashboard : pont pour qu'un CLIENT enregistre lui-meme
# son propre identifiant de connecteur (formulaire web, pas un terminal).
# Appele par dashboard/server.py (POST /api/connectors/<provider>/credential).
# ClientId/Provider/Value arrivent par -InFile (JSON), jamais interpoles
# dans une commande PowerShell (meme raison que Confirm-Connector-Action.ps1).
# La valeur en clair transite en memoire le temps du chiffrement puis
# n'est jamais journalisee ni renvoyee dans -OutFile.
# =====================================================================

param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/connectors/Client-Credential-Store.ps1")

$Request = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json

$Result = try {
    if (-not $Request.clientId -or -not $Request.provider) {
        @{ ok = $false; error = "MISSING_FIELDS" }
    }
    elseif (-not $Request.value) {
        # Valeur vide = demande de suppression, pas d'erreur.
        $Removed = Remove-BKClientCredential -ClientId $Request.clientId -Provider $Request.provider
        @{ ok = $true; removed = $Removed }
    }
    else {
        Set-BKClientCredentialValue -ClientId $Request.clientId -Provider $Request.provider -PlainText $Request.value
        @{ ok = $true; stored = $true }
    }
} catch {
    @{ ok = $false; error = $_.Exception.Message }
}

($Result | ConvertTo-Json -Compress) | Set-Content -LiteralPath $OutFile -Encoding UTF8
