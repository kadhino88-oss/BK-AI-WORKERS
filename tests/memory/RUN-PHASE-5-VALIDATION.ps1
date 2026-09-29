$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$EnginePath = Join-Path $Root "memory\engine"
$TestsPath = Join-Path $Root "tests\memory"
$RuntimePath = Join-Path $Root "memory\runtime"

$ClientId = "bk-entreprise"
$ProjectId = "service-ia"
$WorkerId = "MAYA"
$TaskId = "TASK-20260909-143327-588"

$Passed = 0
$Failed = 0

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 5 - MEMORY & CONTEXT"
Write-Host " FINAL VALIDATION"
Write-Host "============================================"
Write-Host ""

function Test-Pass {
    param([string]$Name)

    Write-Host "PASS : $Name"
    $script:Passed++
}

function Test-Fail {
    param([string]$Name)

    Write-Host "FAIL : $Name"
    $script:Failed++
}

# =================================================
# TEST 1 - CONTEXTE ACTIF
# =================================================

Write-Host "TEST 1 : CONTEXTE ACTIF"

$ActiveFile = Join-Path $RuntimePath "ACTIVE-$TaskId.json"

if (Test-Path $ActiveFile) {
    try {
        $ActiveContext = Get-Content $ActiveFile -Raw | ConvertFrom-Json

        if (
            $ActiveContext.client.id -eq $ClientId -and
            $ActiveContext.project.id -eq $ProjectId -and
            $ActiveContext.worker.id -eq $WorkerId -and
            $ActiveContext.task.id -eq $TaskId
        ) {
            Test-Pass "Contexte actif valide"
        }
        else {
            Test-Fail "Identite du contexte incorrecte"
        }
    }
    catch {
        Test-Fail "JSON du contexte actif invalide"
    }
}
else {
    Test-Fail "Contexte actif absent"
}

Write-Host ""

# =================================================
# TEST 2 - MEMOIRE HIERARCHIQUE
# =================================================

Write-Host "TEST 2 : MEMOIRE HIERARCHIQUE"

$HierarchicalFile = Join-Path $RuntimePath "HIERARCHICAL-$TaskId.json"

if (Test-Path $HierarchicalFile) {

    try {

        $Hierarchical = Get-Content $HierarchicalFile -Raw | ConvertFrom-Json

        $levelsOK = $true

        foreach ($level in @(
            "global",
            "client",
            "project",
            "worker",
            "task",
            "execution"
        )) {

            if ($null -eq $Hierarchical.hierarchy.$level) {
                $levelsOK = $false
            }
        }

        if ($levelsOK) {
            Test-Pass "6 niveaux hierarchiques presents"
        }
        else {
            Test-Fail "Hierarchie incomplete"
        }
    }
    catch {
        Test-Fail "JSON hierarchique invalide"
    }
}
else {
    Test-Fail "Memoire hierarchique absente"
}

Write-Host ""

# =================================================
# TEST 3 - ISOLATION CLIENT
# =================================================

Write-Host "TEST 3 : ISOLATION CLIENT"

if ($Hierarchical.context.client_id -eq "bk-entreprise") {
    Test-Pass "Client correctement isole"
}
else {
    Test-Fail "Client incorrect"
}

Write-Host ""

# =================================================
# TEST 4 - ISOLATION WORKER
# =================================================

Write-Host "TEST 4 : ISOLATION WORKER"

if ($Hierarchical.context.worker_id -eq "MAYA") {
    Test-Pass "Worker correctement isole"
}
else {
    Test-Fail "Worker incorrect"
}

Write-Host ""

# =================================================
# TEST 5 - ABSENCE CROSS-CLIENT
# =================================================

Write-Host "TEST 5 : CROSS-CLIENT"

$HierarchicalText = Get-Content $HierarchicalFile -Raw

if ($HierarchicalText -notmatch "client-demo") {
    Test-Pass "Aucune donnee client-demo"
}
else {
    Test-Fail "Donnee client-demo detectee"
}

Write-Host ""

# =================================================
# TEST 6 - ABSENCE CROSS-WORKER
# =================================================

Write-Host "TEST 6 : CROSS-WORKER"

if ($HierarchicalText -notmatch '"worker_id"\s*:\s*"LUCAS"') {
    Test-Pass "Aucune donnee LUCAS"
}
else {
    Test-Fail "Donnee LUCAS detectee"
}

Write-Host ""

# =================================================
# TEST 7 - PERMISSIONS
# =================================================

Write-Host "TEST 7 : PERMISSIONS"

if (
    $ActiveContext.permissions.read -eq $true -and
    $ActiveContext.permissions.write -eq $true
) {
    Test-Pass "READ / WRITE autorises"
}
else {
    Test-Fail "Permissions READ / WRITE invalides"
}

Write-Host ""

# =================================================
# TEST 8 - ACTIONS EXTERNES
# =================================================

Write-Host "TEST 8 : ACTIONS EXTERNES"

if ($ActiveContext.permissions.external_actions -eq $false) {
    Test-Pass "Actions externes bloquees"
}
else {
    Test-Fail "Actions externes autorisees"
}

Write-Host ""

# =================================================
# TEST 9 - ACTIONS FINANCIERES
# =================================================

Write-Host "TEST 9 : FRONTIERE FINANCIERE"

if ($ActiveContext.permissions.financial_actions -eq $false) {
    Test-Pass "Actions financieres bloquees"
}
else {
    Test-Fail "Actions financieres autorisees"
}

Write-Host ""

# =================================================
# TEST 10 - MEMORY LIFECYCLE
# =================================================

Write-Host "TEST 10 : MEMORY LIFECYCLE"

$Lifecycle = Join-Path $EnginePath "Memory-Lifecycle.ps1"

$TestKey = "phase5-final-test"

& $Lifecycle `
    -Action WRITE `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -MemoryKey $TestKey `
    -Value "Phase 5 validation"

if ($LASTEXITCODE -eq 0) {
    Test-Pass "WRITE"
}
else {
    Test-Fail "WRITE"
}

& $Lifecycle `
    -Action READ `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -MemoryKey $TestKey

if ($LASTEXITCODE -eq 0) {
    Test-Pass "READ"
}
else {
    Test-Fail "READ"
}

& $Lifecycle `
    -Action UPDATE `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -MemoryKey $TestKey `
    -Value "Phase 5 updated"

if ($LASTEXITCODE -eq 0) {
    Test-Pass "UPDATE"
}
else {
    Test-Fail "UPDATE"
}

& $Lifecycle `
    -Action DELETE `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -MemoryKey $TestKey

if ($LASTEXITCODE -eq 0) {
    Test-Pass "DELETE"
}
else {
    Test-Fail "DELETE"
}

Write-Host ""

# =================================================
# RESULTAT FINAL
# =================================================

Write-Host "============================================"
Write-Host " RESULTAT FINAL PHASE 5"
Write-Host "============================================"
Write-Host ""

Write-Host "TESTS PASSES  : $Passed"
Write-Host "TESTS ECHOUES : $Failed"
Write-Host ""

if ($Failed -eq 0) {

    Write-Host "============================================"
    Write-Host " MEMORY & CONTEXT : SECURE"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "PHASE 5 : VALIDEE"
    Write-Host "SYSTEME PRET POUR INTEGRATION ORCHESTRATEUR"
    Write-Host ""

    exit 0
}

Write-Host "============================================"
Write-Host " MEMORY & CONTEXT : FAIL"
Write-Host "============================================"

exit 20