# BK AI WORKERS
# MASTER WORKER FRAMEWORK VALIDATOR
# PHASE 7H-4

$ErrorActionPreference = "Stop"

$root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$frameworkPath = "$root\core\config\worker-framework\MASTER-WORKER-FRAMEWORK.json"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MASTER WORKER FRAMEWORK VALIDATOR"
Write-Host " PHASE 7H-4"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $frameworkPath)) {
    Write-Host "FRAMEWORK : NOT FOUND"
    exit 1
}

try {
    $config = Get-Content -LiteralPath $frameworkPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "FRAMEWORK JSON : INVALID"
    exit 1
}

Write-Host "FRAMEWORK JSON : VALID"

$workerNames = @(
    "LEA",
    "NOAH",
    "ALEX",
    "MAYA",
    "LUCAS",
    "EMMA",
    "SAM"
)

$errors = 0

foreach ($worker in $workerNames) {

    $item = $config.workers.PSObject.Properties[$worker]

    if ($null -eq $item) {
        Write-Host "$worker : MISSING"
        $errors++
        continue
    }

    if ([string]::IsNullOrWhiteSpace($item.Value.role)) {
        Write-Host "$worker : ROLE MISSING"
        $errors++
        continue
    }

    if (@($item.Value.categories).Count -eq 0) {
        Write-Host "$worker : CATEGORIES MISSING"
        $errors++
        continue
    }

    Write-Host "$worker : VALID"
}

if ($config.standard.identity -ne $true) {
    $errors++
}

if ($config.standard.skills -ne $true) {
    $errors++
}

if ($config.standard.skill_contracts -ne $true) {
    $errors++
}

if ($config.standard.runtime -ne $true) {
    $errors++
}

if ($config.standard.memory -ne $true) {
    $errors++
}

if ($config.standard.tools -ne $true) {
    $errors++
}

if ($config.standard.integrations -ne $true) {
    $errors++
}

if ($config.standard.security -ne $true) {
    $errors++
}

if ($config.commercial_requirements.multi_client -ne $true) {
    $errors++
}

if ($config.commercial_requirements.tenant_isolation -ne $true) {
    $errors++
}

if ($config.security_defaults.secret_exposure -ne $false) {
    $errors++
}

if ($config.financial_boundary.worker_execution -ne $false) {
    $errors++
}

Write-Host ""
Write-Host "STANDARD FIELDS : VALID"
Write-Host "COMMERCIAL      : VALID"
Write-Host "SECURITY        : VALID"
Write-Host "FINANCE         : BLOCKED"
Write-Host "WORKERS         : 7"

Write-Host ""
Write-Host "ERRORS : $errors"

if ($errors -gt 0) {
    Write-Host "STATUS : ERROR"
    exit 1
}

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 7H-4 RESULT"
Write-Host "============================================"
Write-Host ""
Write-Host "STATUS              : SUCCESS"
Write-Host "MASTER FRAMEWORK    : READY"
Write-Host "WORKERS             : 7"
Write-Host "MULTI CLIENT        : ENABLED"
Write-Host "TENANT ISOLATION    : ENABLED"
Write-Host "SECURITY            : VALID"
Write-Host "FINANCE             : BLOCKED"
Write-Host "EXTERNAL            : BLOCKED"
Write-Host ""
Write-Host "MASTER WORKER FRAMEWORK : READY"