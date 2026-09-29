$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\security\credentials"
$CatalogPath = Join-Path $Dir "CREDENTIAL-STORE-CATALOG.json"
$Validator = Join-Path $Dir "Validate-Credential-Store.ps1"
$Resolver = Join-Path $Dir "CREDENTIAL-RESOLVER.ps1"

$Pass = 0
$Fail = 0

function Pass-Test($message) {
    $script:Pass++
    Write-Host "PASS : $message" -ForegroundColor Green
}

function Fail-Test($message) {
    $script:Fail++
    Write-Host "FAIL : $message" -ForegroundColor Red
}

Write-Host ""
Write-Host "============================================="
Write-Host "7H-19 - CREDENTIAL RESOLVER / SECRET STORE"
Write-Host "============================================="
Write-Host ""

# TEST 1
try {
    & $Validator $CatalogPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Credential Store valide"
    }
    else {
        Fail-Test "Credential Store invalide"
    }
}
catch {
    Fail-Test "validation du Credential Store"
}

. $Resolver

# TEST 2
$result = Resolve-CredentialReference `
    -CatalogPath $CatalogPath `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $result.status -eq "RESOLVED" -and
    $result.credentialRef -eq "cred.client001.gmail"
) {
    Pass-Test "credential GMAIL correctement résolu"
}
else {
    Fail-Test "résolution GMAIL incorrecte"
}

# TEST 3
if (
    $null -eq $result.secret -and
    $null -eq $result.apiKey -and
    $null -eq $result.accessToken -and
    $null -eq $result.password -and
    $result.secretExposure -eq $false
) {
    Pass-Test "aucun secret brut exposé"
}
else {
    Fail-Test "secret brut exposé"
}

# TEST 4
$result = Resolve-CredentialReference `
    -CatalogPath $CatalogPath `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Provider "UNKNOWN" `
    -Category "UNKNOWN"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CREDENTIAL_NOT_FOUND"
) {
    Pass-Test "credential inconnu bloqué"
}
else {
    Fail-Test "credential inconnu non bloqué"
}

# TEST 5
$result = Resolve-CredentialReference `
    -CatalogPath $CatalogPath `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-999" `
    -ProjectId "PROJECT-001" `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CREDENTIAL_NOT_FOUND"
) {
    Pass-Test "isolation client respectée"
}
else {
    Fail-Test "isolation client contournable"
}

# TEST 6
$result = Resolve-CredentialReference `
    -CatalogPath $CatalogPath `
    -TenantId "TENANT-999" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CREDENTIAL_NOT_FOUND"
) {
    Pass-Test "isolation tenant respectée"
}
else {
    Fail-Test "isolation tenant contournable"
}

# TEST 7
$result = Resolve-CredentialReference `
    -CatalogPath $CatalogPath `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "" `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONTEXT_INCOMPLETE"
) {
    Pass-Test "projectId vide bloqué"
}
else {
    Fail-Test "projectId vide non bloqué"
}

# TEST 8
$result = Resolve-CredentialReference `
    -CatalogPath $CatalogPath `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Provider "WORDPRESS" `
    -Category "CMS"

$handle = Get-AdapterCredentialHandle -ResolvedCredential $result

if (
    $handle.status -eq "AUTHORIZED" -and
    $handle.credentialRef -eq "cred.client001.wordpress" -and
    $null -eq $handle.secret -and
    $null -eq $handle.apiKey -and
    $null -eq $handle.accessToken -and
    $handle.secretExposure -eq $false
) {
    Pass-Test "handle Adapter autorisé sans secret brut"
}
else {
    Fail-Test "handle Adapter non conforme"
}

Write-Host ""
Write-Host "RESULTATS 7H-19"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Credential Resolver / Secret Store opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1