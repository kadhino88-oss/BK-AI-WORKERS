param(
    [Parameter(Mandatory = $true)]
    [string]$CatalogPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $CatalogPath)) {
    throw "Credential catalog introuvable."
}

$raw = Get-Content -LiteralPath $CatalogPath -Raw -Encoding UTF8

try {
    $catalog = $raw | ConvertFrom-Json
}
catch {
    throw "JSON invalide : $($_.Exception.Message)"
}

$errors = New-Object System.Collections.Generic.List[string]

if ($catalog.catalogVersion -ne "1.0") {
    $errors.Add("Version de catalogue incorrecte.")
}

if ($catalog.security.storeRawSecrets -ne $false) {
    $errors.Add("storeRawSecrets doit être false.")
}

if ($catalog.security.returnRawSecretsToWorkers -ne $false) {
    $errors.Add("returnRawSecretsToWorkers doit être false.")
}

if ($catalog.security.returnRawSecretsToLogs -ne $false) {
    $errors.Add("returnRawSecretsToLogs doit être false.")
}

if ($catalog.security.tenantIsolation -ne $true) {
    $errors.Add("tenantIsolation doit être true.")
}

if ($catalog.security.clientIsolation -ne $true) {
    $errors.Add("clientIsolation doit être true.")
}

if ($catalog.security.projectIsolation -ne $true) {
    $errors.Add("projectIsolation doit être true.")
}

foreach ($credential in $catalog.credentials) {

    $serialized = $credential | ConvertTo-Json -Depth 20 -Compress

    $forbidden = @(
        "api_key",
        "apikey",
        "access_token",
        "refresh_token",
        "client_secret",
        "clientsecret",
        "password",
        "passwd",
        "private_key",
        "privatekey",
        "bearer"
    )

    foreach ($token in $forbidden) {
        if ($serialized -match [regex]::Escape($token)) {
            $errors.Add(
                "Champ sensible détecté dans credentialRef=$($credential.credentialRef) : $token"
            )
        }
    }

    if ([string]::IsNullOrWhiteSpace($credential.credentialRef)) {
        $errors.Add("Credential sans credentialRef.")
    }
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "VALIDATION CREDENTIAL STORE : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "CREDENTIAL STORE : VALIDE" -ForegroundColor Green
Write-Host "Version : $($catalog.catalogVersion)"
Write-Host "Credentials référencés : $($catalog.credentials.Count)"
Write-Host "Secrets bruts stockés : FALSE"
Write-Host "Secrets retournés aux Workers : FALSE"
Write-Host "Secrets retournés aux logs : FALSE"
exit 0