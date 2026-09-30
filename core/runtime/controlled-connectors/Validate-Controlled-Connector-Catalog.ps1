param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    throw "Catalog introuvable."
}

$raw = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8

try {
    $catalog = $raw | ConvertFrom-Json
}
catch {
    throw "JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($catalog.catalogVersion -ne "1.0") {
    $errors.Add("Version catalogue incorrecte.")
}

if ($catalog.liveExecutionEnabled -ne $false) {
    $errors.Add("liveExecutionEnabled doit être false.")
}

if (-not $catalog.connectors) {
    $errors.Add("Aucun connector enregistré.")
}

$ids = @(
    $catalog.connectors | ForEach-Object {
        $_.connectorId
    }
)

foreach ($connector in $catalog.connectors) {

    if ([string]::IsNullOrWhiteSpace($connector.connectorId)) {
        $errors.Add("Connector sans connectorId.")
    }

    if ([string]::IsNullOrWhiteSpace($connector.provider)) {
        $errors.Add("Connector sans provider.")
    }

    if ([string]::IsNullOrWhiteSpace($connector.category)) {
        $errors.Add("Connector sans category.")
    }

    if ([string]::IsNullOrWhiteSpace($connector.adapterId)) {
        $errors.Add("Connector sans adapterId.")
    }

    if ([string]::IsNullOrWhiteSpace($connector.adapterVersion)) {
        $errors.Add("Connector sans adapterVersion.")
    }

    if (-not $connector.operations) {
        $errors.Add(
            "Connector sans operations : $($connector.connectorId)"
        )
    }
}

if ($ids.Count -ne ($ids | Select-Object -Unique).Count) {
    $errors.Add("ConnectorId dupliqué.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION CONTROLLED CONNECTORS : FAIL" -ForegroundColor Red

    foreach ($errorMessage in $errors) {
        Write-Host "FAIL : $errorMessage" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "CONTROLLED CONNECTOR CATALOG : VALIDE" -ForegroundColor Green
Write-Host "Version : $($catalog.catalogVersion)"
Write-Host "Connecteurs : $($catalog.connectors.Count)"
Write-Host "LIVE execution enabled : FALSE"
exit 0