# =====================================================================
# BK-AI-WORKERS — Dashboard : pont CLI vers Connector-Dispatch.ps1.
# Appele par dashboard/server.py (POST /api/connector-action/confirm)
# APRES confirmation explicite du client — jamais automatiquement
# pendant une mission (voir core/ai/adapters/ANTHROPIC-ADAPTER.ps1).
# ConnectorId/Operation/Params arrivent par -InFile (JSON), jamais par
# des arguments de ligne de commande individuels : evite tout risque
# d'injection si un champ contenait un caractere special.
# =====================================================================

param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/integrations/Connector-Dispatch.ps1")

$Request = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json

$Params = @{}
if ($Request.params) {
    $Request.params.PSObject.Properties | ForEach-Object { $Params[$_.Name] = $_.Value }
}

$Result = Invoke-ConnectorAction -ConnectorId $Request.connectorId -Operation $Request.operation -ClientId $Request.clientId -Params $Params

($Result | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $OutFile -Encoding UTF8
