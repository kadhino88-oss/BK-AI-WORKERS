$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$RuntimePath = Join-Path $Root "memory\runtime"

$TargetFile = Join-Path $RuntimePath "HIERARCHICAL-TASK-20260909-143327-588.json"

Write-Host ""
Write-Host "============================================"
Write-Host " HIERARCHICAL MEMORY ISOLATION TEST"
Write-Host " PHASE 5E-3"
Write-Host "============================================"
Write-Host ""

if (-not (Test-Path $TargetFile)) {
    Write-Host "RESULTAT : FAIL"
    Write-Host "RAISON : CONTEXTE HIERARCHIQUE INTROUVABLE"
    exit 10
}

try {
    $context = Get-Content $TargetFile -Raw | ConvertFrom-Json
}
catch {
    Write-Host "RESULTAT : FAIL"
    Write-Host "RAISON : JSON INVALIDE"
    exit 11
}

$passed = 0
$failed = 0

# -------------------------------------------------
# IDENTITE
# -------------------------------------------------

Write-Host "TEST 1 : IDENTITE DU CONTEXTE"

if (
    $context.context.client_id -eq "bk-entreprise" -and
    $context.context.project_id -eq "service-ia" -and
    $context.context.worker_id -eq "MAYA" -and
    $context.context.task_id -eq "TASK-20260909-143327-588"
) {
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# PRESENCE DES 6 NIVEAUX
# -------------------------------------------------

Write-Host "TEST 2 : HIERARCHIE COMPLETE"

$levels = @(
    "global",
    "client",
    "project",
    "worker",
    "task",
    "execution"
)

$hierarchyOK = $true

foreach ($level in $levels) {

    $value = $context.hierarchy.$level

    if ($null -eq $value) {
        Write-Host "$level : FAIL"
        $hierarchyOK = $false
    }
    elseif ($value.Count -ge 1) {
        Write-Host "$level : OK"
    }
    else {
        Write-Host "$level : VIDE"
    }
}

if ($hierarchyOK) {
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# VERIFICATION CLIENT
# -------------------------------------------------

Write-Host "TEST 3 : ISOLATION CLIENT"

$clientOK = $true

foreach ($item in $context.hierarchy.client) {

    if ($item.data.client_id -ne "bk-entreprise") {
        $clientOK = $false
    }
}

if ($clientOK) {
    Write-Host "CLIENT : bk-entreprise"
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# VERIFICATION PROJET
# -------------------------------------------------

Write-Host "TEST 4 : ISOLATION PROJET"

$projectOK = $true

foreach ($item in $context.hierarchy.project) {

    if ($item.data.project_id -ne "service-ia") {
        $projectOK = $false
    }
}

if ($projectOK) {
    Write-Host "PROJECT : service-ia"
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# VERIFICATION WORKER
# -------------------------------------------------

Write-Host "TEST 5 : ISOLATION WORKER"

$workerOK = $true

foreach ($item in $context.hierarchy.worker) {

    if ($item.data.worker_id -ne "MAYA") {
        $workerOK = $false
    }
}

if ($workerOK) {
    Write-Host "WORKER : MAYA"
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# DETECTION CROSS-CLIENT
# -------------------------------------------------

Write-Host "TEST 6 : DETECTION CROSS-CLIENT"

$crossClient = $false

$jsonText = Get-Content $TargetFile -Raw

if ($jsonText -match "client-demo") {
    $crossClient = $true
}

if (-not $crossClient) {
    Write-Host "CLIENT-DEMO : ABSENT"
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "CLIENT-DEMO : DETECTE"
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# DETECTION CROSS-WORKER
# -------------------------------------------------

Write-Host "TEST 7 : DETECTION CROSS-WORKER"

$crossWorker = $false

if ($jsonText -match '"worker_id"\s*:\s*"LUCAS"') {
    $crossWorker = $true
}

if (-not $crossWorker) {
    Write-Host "LUCAS : ABSENT"
    Write-Host "RESULTAT : PASS"
    $passed++
}
else {
    Write-Host "LUCAS : DETECTE"
    Write-Host "RESULTAT : FAIL"
    $failed++
}

Write-Host ""

# -------------------------------------------------
# RESULTAT FINAL
# -------------------------------------------------

Write-Host "============================================"
Write-Host " RESULTAT FINAL"
Write-Host "============================================"
Write-Host ""

Write-Host "TESTS PASSES  : $passed"
Write-Host "TESTS ECHOUES : $failed"
Write-Host ""

if ($failed -eq 0) {

    Write-Host "HIERARCHICAL MEMORY : SECURE"
    Write-Host "CROSS-CLIENT       : BLOQUE"
    Write-Host "CROSS-WORKER       : BLOQUE"
    Write-Host "PHASE 5E-3         : VALIDEE"

    exit 0
}

Write-Host "HIERARCHICAL MEMORY : FAIL"
exit 20