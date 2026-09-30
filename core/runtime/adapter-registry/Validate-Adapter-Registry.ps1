param(
    [Parameter(Mandatory = $true)]
    [string]$RegistryPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $RegistryPath)) {
    throw "Registry introuvable."
}

$raw = Get-Content -LiteralPath $RegistryPath -Raw -Encoding UTF8

try {
    $registry = $raw | ConvertFrom-Json
}
catch {
    throw "JSON invalide : $($_.Exception.Message)"
}

$errors = New-Object System.Collections.Generic.List[string]

if ($registry.registryVersion -ne "1.0") {
    $errors.Add("registryVersion doit être 1.0.")
}

if (-not $registry.adapters) {
    $errors.Add("Aucun adapter enregistré.")
}

if (-not $registry.providerBindings) {
    $errors.Add("Aucun provider binding.")
}

if ($registry.defaults.secretsStoredHere -ne $false) {
    $errors.Add("Le Registry ne doit jamais stocker de secrets.")
}

$adapterIds = @(
    $registry.adapters | ForEach-Object { $_.adapterId }
)

foreach ($adapter in $registry.adapters) {
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
}

foreach ($binding in $registry.providerBindings) {
    if ($adapterIds -notcontains $binding.adapterId) {
        $errors.Add(
            "Binding vers adapter non enregistré : $($binding.adapterId)"
        )
    }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "VALIDATION ADAPTER REGISTRY : FAIL" -ForegroundColor Red

    foreach ($errorMessage in $errors) {
        Write-Host "FAIL : $errorMessage" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "ADAPTER REGISTRY : VALIDE" -ForegroundColor Green
Write-Host "Version : $($registry.registryVersion)"
Write-Host "Adapters enregistrés : $($registry.adapters.Count)"
Write-Host "Provider bindings : $($registry.providerBindings.Count)"
Write-Host "Secrets stockés dans le Registry : FALSE"
exit 0