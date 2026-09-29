$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\adapter-factory"

$CatalogPath = Join-Path `
    $Dir `
    "ADAPTER-FACTORY-CATALOG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Adapter-Factory.ps1"

$Runtime = Join-Path `
    $Dir `
    "ADAPTER-FACTORY-RUNTIME.ps1"

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
Write-Host "7H-21 - ADAPTER FACTORY & LIFECYCLE"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $CatalogPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Adapter Factory Catalog valide"
    }
    else {
        Fail-Test "Adapter Factory Catalog invalide"
    }
}
catch {
    Fail-Test "validation Adapter Factory"
}

. $Runtime

# ============================================================
# TEST 2
# Création instance Gmail
# ============================================================

$gmail = New-AdapterInstance `
    -CatalogPath $CatalogPath `
    -AdapterId "gmail.default" `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $gmail.status -eq "CREATED" -and
    $gmail.adapterId -eq "gmail.default" -and
    $gmail.health -eq "HEALTHY" -and
    $gmail.externalCallAllowed -eq $false -and
    $gmail.secretExposure -eq $false
) {
    Pass-Test "instance GMAIL créée sans appel externe"
}
else {
    Fail-Test "création instance GMAIL incorrecte"
}

# ============================================================
# TEST 3
# Provider incorrect
# ============================================================

$result = New-AdapterInstance `
    -CatalogPath $CatalogPath `
    -AdapterId "gmail.default" `
    -Provider "WORDPRESS" `
    -Category "CMS"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "ADAPTER_NOT_REGISTERED"
) {
    Pass-Test "mauvais binding provider bloqué"
}
else {
    Fail-Test "mauvais binding provider non bloqué"
}

# ============================================================
# TEST 4
# Adapter inconnu
# ============================================================

$result = New-AdapterInstance `
    -CatalogPath $CatalogPath `
    -AdapterId "unknown.adapter" `
    -Provider "UNKNOWN" `
    -Category "UNKNOWN"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "ADAPTER_NOT_REGISTERED"
) {
    Pass-Test "adapter inconnu bloqué"
}
else {
    Fail-Test "adapter inconnu non bloqué"
}

# ============================================================
# TEST 5
# Adapter Stripe désactivé
# ============================================================

$result = New-AdapterInstance `
    -CatalogPath $CatalogPath `
    -AdapterId "stripe.default" `
    -Provider "STRIPE" `
    -Category "PAYMENT"

if (
    $result.status -eq "BLOCKED" -and
    (
        $result.reason -eq "ADAPTER_DISABLED" -or
        $result.reason -eq "ADAPTER_LIFECYCLE_DISABLED"
    )
) {
    Pass-Test "adapter Stripe désactivé correctement bloqué"
}
else {
    Fail-Test "adapter Stripe désactivé non bloqué"
}

# ============================================================
# TEST 6
# Health
# ============================================================

$health = Get-AdapterHealth -AdapterInstance $gmail

if (
    $health.status -eq "HEALTHY" -and
    $health.externalCallAllowed -eq $false
) {
    Pass-Test "health adapter conforme"
}
else {
    Fail-Test "health adapter incorrect"
}

# ============================================================
# TEST 7
# Lifecycle
# ============================================================

$lifecycle = Set-AdapterLifecycle `
    -CatalogPath $CatalogPath `
    -AdapterId "gmail.default" `
    -Lifecycle "READY"

if (
    $lifecycle.status -eq "LIFECYCLE_UPDATED" -and
    $lifecycle.requestedLifecycle -eq "READY" -and
    $lifecycle.externalCallPerformed -eq $false
) {
    Pass-Test "cycle de vie READY préparé sans appel externe"
}
else {
    Fail-Test "cycle de vie incorrect"
}

# ============================================================
# TEST 8
# AdapterId vide
# ============================================================

$result = New-AdapterInstance `
    -CatalogPath $CatalogPath `
    -AdapterId "" `
    -Provider "GMAIL" `
    -Category "EMAIL"

if (
    $result.status -eq "BLOCKED" -and
    $result.reason -eq "ADAPTER_ID_REQUIRED"
) {
    Pass-Test "AdapterId vide bloqué"
}
else {
    Fail-Test "AdapterId vide non bloqué"
}

# ============================================================
# TEST 9
# LIVE désactivé
# ============================================================

if ($gmail.supportsLive -eq $false) {
    Pass-Test "LIVE explicitement désactivé"
}
else {
    Fail-Test "LIVE ne devrait pas être disponible"
}

# ============================================================
# TEST 10
# Secret exposition
# ============================================================

if (
    $gmail.secretExposure -eq $false
) {
    Pass-Test "aucune exposition de secret"
}
else {
    Fail-Test "exposition de secret détectée"
}

Write-Host ""
Write-Host "RESULTATS 7H-21"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Adapter Factory & Lifecycle opérationnels."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1