param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    throw "Catalog Factory introuvable."
}

try {
    $catalog =
        Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "JSON Factory invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($catalog.factoryVersion -ne "1.0") {
    $errors.Add("factoryVersion incorrecte.")
}

if ($catalog.liveCreationEnabled -ne $false) {
    $errors.Add("liveCreationEnabled doit être false.")
}

if (-not $catalog.adapters) {
    $errors.Add("Aucun adapter défini.")
}

$ids = @(
    $catalog.adapters | ForEach-Object {
        $_.adapterId
    }
)

if ($ids.Count -ne ($ids | Select-Object -Unique).Count) {
    $errors.Add("AdapterId dupliqué.")
}

$allowedLifecycle = @(
    "REGISTERED",
    "READY",
    "ENABLED",
    "DISABLED",
    "DEPRECATED"
)

foreach ($adapter in $catalog.adapters) {

    if ([string]::IsNullOrWhiteSpace($adapter.adapterId)) {
        $errors.Add("Adapter sans adapterId.")
    }

    if ([string]::IsNullOrWhiteSpace($adapter.provider)) {
        $errors.Add("Adapter sans provider.")
    }

    if ([string]::IsNullOrWhiteSpace($adapter.category)) {
        $errors.Add("Adapter sans category.")
    }

    if ([string]::IsNullOrWhiteSpace($adapter.version)) {
        $errors.Add("Adapter sans version.")
    }

    if ($allowedLifecycle -notcontains $adapter.lifecycle) {
        $errors.Add(
            "Lifecycle invalide : $($adapter.adapterId)"
        )
    }

    if ($adapter.supportsLive -ne $false) {
        $errors.Add(
            "supportsLive doit rester false dans 7H-21 : $($adapter.adapterId)"
        )
    }
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION ADAPTER FACTORY : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "ADAPTER FACTORY : VALIDE" -ForegroundColor Green
Write-Host "Version : $($catalog.factoryVersion)"
Write-Host "Adapters : $($catalog.adapters.Count)"
Write-Host "LIVE creation : FALSE"
Write-Host "LIVE adapter support : FALSE"
exit 0