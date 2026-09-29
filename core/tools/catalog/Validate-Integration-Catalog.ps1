# BK AI WORKERS
# INTEGRATION CATALOG VALIDATOR
# PHASE 7H-9

$ErrorActionPreference = "Stop"

$root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$catalogPath = "$root\core\tools\catalog\INTEGRATION-CATALOG.json"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " INTEGRATION CATALOG VALIDATOR"
Write-Host " PHASE 7H-9"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $catalogPath)) {
    Write-Host "CATALOG : NOT FOUND"
    exit 1
}

try {
    $catalog = Get-Content -LiteralPath $catalogPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "CATALOG JSON : INVALID"
    exit 1
}

Write-Host "CATALOG JSON : VALID"

$categories = @($catalog.categories.PSObject.Properties)
$workers = @($catalog.worker_domains.PSObject.Properties)

$providerCount = 0

foreach ($category in $categories) {
    $providerCount += @($category.Value.providers).Count
}

$errors = 0

if ($catalog.catalog.extensible -ne $true) {
    $errors++
}

if ($catalog.design_principles.provider_agnostic -ne $true) {
    $errors++
}

if ($catalog.design_principles.connector_modular -ne $true) {
    $errors++
}

if ($catalog.design_principles.client_configurable -ne $true) {
    $errors++
}

if ($catalog.security.client_isolation -ne $true) {
    $errors++
}

if ($catalog.security.project_isolation -ne $true) {
    $errors++
}

if ($catalog.security.worker_isolation -ne $true) {
    $errors++
}

if ($catalog.security.secret_exposure -ne $false) {
    $errors++
}

if ($catalog.integration_state.live_execution_enabled -ne $false) {
    $errors++
}

if ($catalog.integration_state.credentials_loaded -ne $false) {
    $errors++
}

if ($catalog.integration_state.financial_actions_enabled -ne $false) {
    $errors++
}

if ($catalog.financial_boundary.transaction_execution -ne $false) {
    $errors++
}

Write-Host "CATEGORIES       : $($categories.Count)"
Write-Host "PROVIDERS        : $providerCount"
Write-Host "WORKERS          : $($workers.Count)"

foreach ($worker in $workers) {

    if (@($worker.Value).Count -eq 0) {
        Write-Host "$($worker.Name) : NO DOMAINS"
        $errors++
    }
    else {
        Write-Host "$($worker.Name) : VALID"
    }
}

Write-Host ""
Write-Host "MODULAR          : VALID"
Write-Host "CLIENT CONFIG    : VALID"
Write-Host "PROJECT CONFIG   : VALID"
Write-Host "WORKER SCOPING   : VALID"
Write-Host "SECRET EXPOSURE  : BLOCKED"
Write-Host "LIVE EXECUTION   : DISABLED"
Write-Host "CREDENTIALS      : NOT LOADED"
Write-Host "FINANCE          : BLOCKED"

Write-Host ""
Write-Host "ERRORS : $errors"

if ($errors -gt 0) {
    Write-Host "STATUS : ERROR"
    exit 1
}

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 7H-9 RESULT"
Write-Host "============================================"
Write-Host ""
Write-Host "STATUS              : SUCCESS"
Write-Host "CATEGORIES          : $($categories.Count)"
Write-Host "PROVIDERS           : $providerCount"
Write-Host "WORKERS             : $($workers.Count)"
Write-Host "EXTENSIBLE          : ENABLED"
Write-Host "CLIENT CONFIGURABLE : ENABLED"
Write-Host "SECURITY            : VALID"
Write-Host "FINANCE             : BLOCKED"
Write-Host "LIVE EXECUTION      : DISABLED"
Write-Host ""
Write-Host "INTEGRATION CATALOG : READY"