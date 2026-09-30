param(
    [Parameter(Mandatory = $true)]
    [string]$ContractPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ContractPath)) {
    throw "Contract introuvable : $ContractPath"
}

$raw = Get-Content -LiteralPath $ContractPath -Raw -Encoding UTF8

try {
    $schema = $raw | ConvertFrom-Json
}
catch {
    throw "JSON invalide : $($_.Exception.Message)"
}

$errors = New-Object System.Collections.Generic.List[string]

if ($schema.'$schema' -ne "https://json-schema.org/draft/2020-12/schema") {
    $errors.Add("Schema JSON incorrect.")
}

if ($schema.title -ne "BK-AI-WORKERS Integration Adapter Contract") {
    $errors.Add("Titre de contrat incorrect.")
}

if (-not $schema.required -or $schema.required.Count -lt 6) {
    $errors.Add("Liste des propriétés obligatoires incomplète.")
}

$requiredTop = @(
    "contractVersion",
    "adapter",
    "execution",
    "request",
    "security",
    "response"
)

foreach ($name in $requiredTop) {
    if ($schema.required -notcontains $name) {
        $errors.Add("Propriété obligatoire absente : $name")
    }
}

if ($schema.properties.contractVersion.const -ne "1.0") {
    $errors.Add("Version de contrat invalide.")
}

if ($schema.properties.security.properties.secretsProvidedToAdapter.const -ne $false) {
    $errors.Add("Règle secretsProvidedToAdapter doit rester false.")
}

if ($schema.properties.security.properties.tenantIsolation.const -ne $true) {
    $errors.Add("tenantIsolation doit être true.")
}

if ($schema.properties.security.properties.clientIsolation.const -ne $true) {
    $errors.Add("clientIsolation doit être true.")
}

if ($schema.properties.security.properties.projectIsolation.const -ne $true) {
    $errors.Add("projectIsolation doit être true.")
}

if ($errors.Count -gt 0) {
    foreach ($e in $errors) {
        Write-Host "FAIL : $e" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "VALIDATION DU CONTRAT : FAIL" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "CONTRAT ADAPTER : VALIDE" -ForegroundColor Green
Write-Host "Version : $($schema.properties.contractVersion.const)"
Write-Host "Secrets fournis directement à l'Adapter : FALSE"
Write-Host "Isolation tenant/client/project : TRUE / TRUE / TRUE"
exit 0