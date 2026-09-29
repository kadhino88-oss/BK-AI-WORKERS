$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\adapter-registry"

$RegistryPath = Join-Path $Dir "ADAPTER-REGISTRY.json"
$Validator = Join-Path $Dir "Validate-Adapter-Registry.ps1"
$Runtime = Join-Path $Dir "ADAPTER-REGISTRY-RUNTIME.ps1"

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
Write-Host "7H-18 - ADAPTER REGISTRY & PROVIDER BINDING"
Write-Host "============================================="
Write-Host ""

# TEST 1
try {
    & $Validator $RegistryPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Registry valide"
    }
    else {
        Fail-Test "Registry invalide"
    }
}
catch {
    Fail-Test "validation du Registry"
}

. $Runtime

# TEST 2
$result = Resolve-IntegrationAdapter `
    -RegistryPath $RegistryPath `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $result.status -eq "RESOLVED" -and
    $result.adapterId -eq "gmail.default" -and
    $result.source -eq "PROVIDER_BINDING"
) {
    Pass-Test "GMAIL correctement résolu"
}
else {
    Fail-Test "résolution GMAIL incorrecte"
}

# TEST 3
$result = Resolve-IntegrationAdapter `
    -RegistryPath $RegistryPath `
    -Provider "WORDPRESS" `
    -Category "CMS"

if (
    $result.status -eq "RESOLVED" -and
    $result.adapterId -eq "wordpress.default"
) {
    Pass-Test "WORDPRESS correctement résolu"
}
else {
    Fail-Test "résolution WORDPRESS incorrecte"
}

# TEST 4
$result = Resolve-IntegrationAdapter `
    -RegistryPath $RegistryPath `
    -Provider "UNKNOWN_PROVIDER" `
    -Category "UNKNOWN"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "PROVIDER_NOT_BOUND"
) {
    Pass-Test "provider inconnu bloqué"
}
else {
    Fail-Test "provider inconnu non bloqué"
}

# TEST 5
$result = Resolve-IntegrationAdapter `
    -RegistryPath $RegistryPath `
    -Provider "STRIPE" `
    -Category "PAYMENT"

if (
    $result.status -eq "BLOCKED" -and
    ($result.reason -eq "ADAPTER_DISABLED" -or $result.reason -eq "ADAPTER_STATUS_DISABLED")
) {
    Pass-Test "adapter désactivé correctement bloqué"
}
else {
    Fail-Test "adapter désactivé non bloqué"
}

# TEST 6
$result = Resolve-IntegrationAdapter `
    -RegistryPath $RegistryPath `
    -Provider "GMAIL" `
    -Category "EMAIL" `
    -ProjectId "PROJECT-001"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CLIENT_REQUIRED_FOR_PROJECT_BINDING"
) {
    Pass-Test "project sans client bloqué"
}
else {
    Fail-Test "project sans client non bloqué"
}

# TEST 7
$testRegistry = [System.IO.Path]::GetTempFileName()

$registryObject = Get-Content `
    -LiteralPath $RegistryPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json

$registryObject.clientProjectOverrides = @(
    [pscustomobject]@{
        clientId = "CLIENT-001"
        projectId = "PROJECT-001"
        provider = "CRM"
        category = "CRM"
        adapterId = "crm.default"
        adapterVersion = "1.0.0"
    }
)

$registryObject |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $testRegistry -Encoding UTF8

$result = Resolve-IntegrationAdapter `
    -RegistryPath $testRegistry `
    -Provider "CRM" `
    -Category "CRM" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001"

Remove-Item -LiteralPath $testRegistry -Force

if (
    $result.status -eq "RESOLVED" -and
    $result.source -eq "CLIENT_PROJECT_OVERRIDE" -and
    $result.adapterId -eq "crm.default"
) {
    Pass-Test "override client/project correctement appliqué"
}
else {
    Fail-Test "override client/project incorrect"
}

# TEST 8
$testRegistry = [System.IO.Path]::GetTempFileName()

$registryObject = Get-Content `
    -LiteralPath $RegistryPath `
    -Raw `
    -Encoding UTF8 |
    ConvertFrom-Json

$registryObject.clientProjectOverrides = @(
    [pscustomobject]@{
        clientId = "CLIENT-001"
        projectId = "PROJECT-001"
        provider = "CRM"
        category = "CRM"
        adapterId = "crm.default"
        adapterVersion = "9.9.9"
    }
)

$registryObject |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $testRegistry -Encoding UTF8

$result = Resolve-IntegrationAdapter `
    -RegistryPath $testRegistry `
    -Provider "CRM" `
    -Category "CRM" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001"

Remove-Item -LiteralPath $testRegistry -Force

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "VERSION_MISMATCH"
) {
    Pass-Test "version mismatch correctement bloqué"
}
else {
    Fail-Test "version mismatch non bloqué"
}

Write-Host ""
Write-Host "RESULTATS 7H-18"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Adapter Registry & Provider Binding opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1