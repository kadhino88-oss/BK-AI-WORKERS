$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\rate-limit-quota"
$StateDir = Join-Path $Dir "state"

$ConfigPath = Join-Path `
    $Dir `
    "RATE-LIMIT-QUOTA-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Rate-Limit-Quota.ps1"

$Runtime = Join-Path `
    $Dir `
    "RATE-LIMIT-QUOTA-RUNTIME.ps1"

if (Test-Path -LiteralPath $StateDir) {
    Get-ChildItem `
        -LiteralPath $StateDir `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

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
Write-Host "7H-31 - RATE LIMITING & QUOTA MANAGER"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Rate Limit / Quota Config valide"
    }
    else {
        Fail-Test "Rate Limit / Quota Config invalide"
    }
}
catch {
    Fail-Test "validation Rate Limit / Quota"
}

. $Runtime

# ============================================================
# TEST 2
# Tenant key
# ============================================================

$key = Get-RateLimitKey `
    -Scope "tenant" `
    -TenantId "TENANT-001"

if (
    $key.status -eq "CREATED" -and
    $key.key -eq "TENANT|TENANT-001"
) {
    Pass-Test "clé tenant correctement générée"
}
else {
    Fail-Test "clé tenant incorrecte"
}

# ============================================================
# TEST 3
# Client key isolation
# ============================================================

$key = Get-RateLimitKey `
    -Scope "client" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001"

if (
    $key.status -eq "CREATED" -and
    $key.key -eq "TENANT|TENANT-001|CLIENT|CLIENT-001"
) {
    Pass-Test "clé client correctement isolée"
}
else {
    Fail-Test "clé client incorrecte"
}

# ============================================================
# TEST 4
# Project key
# ============================================================

$key = Get-RateLimitKey `
    -Scope "project" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001"

if (
    $key.status -eq "CREATED" -and
    $key.key -match "PROJECT\|PROJECT-001$"
) {
    Pass-Test "clé projet correctement générée"
}
else {
    Fail-Test "clé projet incorrecte"
}

# ============================================================
# TEST 5
# First quota consumption
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "project" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Units 1

if (
    $result.status -eq "CONSUMED" -and
    $result.consumption -eq 1
) {
    Pass-Test "première consommation de quota enregistrée"
}
else {
    Fail-Test "première consommation incorrecte"
}

# ============================================================
# TEST 6
# Remaining quota
# ============================================================

$result = Test-RateLimit `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "project" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -RequestedUnits 1

if (
    $result.status -eq "ALLOWED" -and
    $result.remaining -eq 23
) {
    Pass-Test "quota restant correctement calculé"
}
else {
    Fail-Test "quota restant incorrect"
}

# ============================================================
# TEST 7
# Quota exceeded
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "project" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -Units 25

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "QUOTA_EXCEEDED"
) {
    Pass-Test "dépassement de quota bloqué"
}
else {
    Fail-Test "dépassement de quota non bloqué"
}

# ============================================================
# TEST 8
# Worker scope
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "worker" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -WorkerId "MAYA" `
    -Units 1

if (
    $result.status -eq "CONSUMED" -and
    $result.scope -eq "worker"
) {
    Pass-Test "quota worker correctement géré"
}
else {
    Fail-Test "quota worker incorrect"
}

# ============================================================
# TEST 9
# Connector scope
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "connector" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "gmail.controlled" `
    -Units 1

if (
    $result.status -eq "CONSUMED" -and
    $result.scope -eq "connector"
) {
    Pass-Test "quota connector correctement géré"
}
else {
    Fail-Test "quota connector incorrect"
}

# ============================================================
# TEST 10
# Client isolation
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "client" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-002" `
    -Units 1

if (
    $result.status -eq "CONSUMED" -and
    $result.key -match "CLIENT\|CLIENT-002$"
) {
    Pass-Test "client différent isolé"
}
else {
    Fail-Test "isolation client incorrecte"
}

# ============================================================
# TEST 11
# Tenant isolation
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "tenant" `
    -TenantId "TENANT-002" `
    -Units 1

if (
    $result.status -eq "CONSUMED" -and
    $result.key -eq "TENANT|TENANT-002"
) {
    Pass-Test "tenant différent isolé"
}
else {
    Fail-Test "isolation tenant incorrecte"
}

# ============================================================
# TEST 12
# Context incomplete
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "project" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "" `
    -Units 1

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "CONTEXT_INCOMPLETE" -and
    $result.field -eq "ProjectId"
) {
    Pass-Test "contexte incomplet bloqué"
}
else {
    Fail-Test "contexte incomplet non bloqué"
}

# ============================================================
# TEST 13
# Negative consumption
# ============================================================

$result = Consume-Quota `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "tenant" `
    -TenantId "TENANT-001" `
    -Units 0

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "INVALID_CONSUMPTION"
) {
    Pass-Test "consommation invalide bloquée"
}
else {
    Fail-Test "consommation invalide non bloquée"
}

# ============================================================
# TEST 14
# No secrets in state
# ============================================================

$secretFound = $false

$files = @(
    Get-ChildItem `
        -LiteralPath $StateDir `
        -Filter "*.json" `
        -File `
        -ErrorAction SilentlyContinue
)

foreach ($file in $files) {

    $content = Get-Content `
        -LiteralPath $file.FullName `
        -Raw `
        -Encoding UTF8

    if (
        $content -match '(?i)"api.?key"\s*:' -or
        $content -match '(?i)"access.?token"\s*:' -or
        $content -match '(?i)"password"\s*:' -or
        $content -match '(?i)"client.?secret"\s*:' -or
        $content -match '(?i)"private.?key"\s*:'
    ) {
        $secretFound = $true
    }
}

if (-not $secretFound) {
    Pass-Test "états de quota sans secret"
}
else {
    Fail-Test "secret détecté dans les états"
}

# ============================================================
# TEST 15
# Rate limit block
# ============================================================

# Projet a actuellement 1 unité.
# Il reste 23 unités sur une limite de 25.
# Demander 24 doit être refusé.

$result = Test-RateLimit `
    -ConfigPath $ConfigPath `
    -StateDirectory $StateDir `
    -Scope "project" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -RequestedUnits 24

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "RATE_LIMIT_EXCEEDED"
) {
    Pass-Test "rate limit dépassée correctement bloquée"
}
else {
    Fail-Test "rate limit dépassée non bloquée"
}

# ============================================================
# TEST 16
# Reset
# ============================================================

$reset = Reset-QuotaState `
    -StateDirectory $StateDir

if (
    $reset.status -eq "RESET"
) {
    Pass-Test "reset des états correctement exécuté"
}
else {
    Fail-Test "reset des états incorrect"
}

Write-Host ""
Write-Host "RESULTATS 7H-31"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Rate Limiting & Quota Manager opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1