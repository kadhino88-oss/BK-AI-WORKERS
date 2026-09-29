$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Builder = "$Root\core\runtime\execution-context\New-Execution-Context.ps1"
$Validator = "$Root\core\runtime\execution-context\Validate-Execution-Context.ps1"
$TestDir = "$Root\tests\7H-13"

$Passed = 0
$Failed = 0

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       BK-AI-WORKERS - PHASE 7H-13" -ForegroundColor Cyan
Write-Host "       EXECUTION CONTEXT VALIDATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

# ============================================================
# PRECHECK
# ============================================================

if (-not (Test-Path -LiteralPath $Builder)) {
    Write-Host "FAIL : Builder absent." -ForegroundColor Red
    exit 1
}

if (-not (Test-Path -LiteralPath $Validator)) {
    Write-Host "FAIL : Validator absent." -ForegroundColor Red
    exit 1
}

Write-Host "Builder   : OK" -ForegroundColor Green
Write-Host "Validator : OK" -ForegroundColor Green

# ============================================================
# TEST 1
# ============================================================

Write-Host ""
Write-Host "TEST 1 : CREATION DU CONTEXTE"

$BuildResult = & $Builder `
    -TenantId "TENANT-7H13-001" `
    -ClientId "CLIENT-7H13-001" `
    -ProjectId "PROJECT-7H13-001" `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -TaskId "TASK-7H13-001" `
    -ToolId "CRM" `
    -Action "READ" `
    -Mode "SIMULATION"

$ContextPath = [string]$BuildResult.path

if (
    -not [string]::IsNullOrWhiteSpace($ContextPath) -and
    (Test-Path -LiteralPath $ContextPath)
) {
    Write-Host "PASS : contexte créé." -ForegroundColor Green
    Write-Host "ExecutionId : $($BuildResult.executionId)"
    Write-Host "Fichier     : $ContextPath"
    $Passed++
}
else {
    Write-Host "FAIL : contexte non créé." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 2
# ============================================================

Write-Host ""
Write-Host "TEST 2 : VALIDATION DU CONTEXTE"

if (
    -not [string]::IsNullOrWhiteSpace($ContextPath) -and
    (Test-Path -LiteralPath $ContextPath)
) {

    & $Validator -ContextPath $ContextPath

    $ValidationCode = $LASTEXITCODE

    if ($ValidationCode -eq 0) {
        Write-Host "PASS : contexte valide." -ForegroundColor Green
        $Passed++
    }
    else {
        Write-Host "FAIL : contexte invalide." -ForegroundColor Red
        $Failed++
    }

}
else {
    Write-Host "FAIL : contexte absent." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 3
# ============================================================

Write-Host ""
Write-Host "TEST 3 : CLIENT VIDE"

try {

    & $Builder `
        -TenantId "TENANT-7H13-001" `
        -ClientId "" `
        -ProjectId "PROJECT-7H13-001" `
        -WorkerId "MAYA" `
        -SkillId "CRM_AUTOMATION" `
        -TaskId "TASK-7H13-003" `
        -ToolId "CRM" `
        -Action "READ" `
        -Mode "SIMULATION" `
        -ErrorAction Stop

    Write-Host "FAIL : client vide accepté." -ForegroundColor Red
    $Failed++

}
catch {

    Write-Host "PASS : client vide bloqué." -ForegroundColor Green
    $Passed++

}

# ============================================================
# TEST 4
# ============================================================

Write-Host ""
Write-Host "TEST 4 : PROJET VIDE"

try {

    & $Builder `
        -TenantId "TENANT-7H13-001" `
        -ClientId "CLIENT-7H13-001" `
        -ProjectId "" `
        -WorkerId "MAYA" `
        -SkillId "CRM_AUTOMATION" `
        -TaskId "TASK-7H13-004" `
        -ToolId "CRM" `
        -Action "READ" `
        -Mode "SIMULATION" `
        -ErrorAction Stop

    Write-Host "FAIL : projet vide accepté." -ForegroundColor Red
    $Failed++

}
catch {

    Write-Host "PASS : projet vide bloqué." -ForegroundColor Green
    $Passed++

}

# ============================================================
# TEST 5
# SECRET
# ============================================================

Write-Host ""
Write-Host "TEST 5 : SECRET DANS LE CONTEXTE"

$SecretTestPath = "$TestDir\EXEC-SECRET-TEST.json"

$SecretObject = [ordered]@{
    schema = "BK-AI-WORKERS-EXECUTION-CONTEXT"
    version = "7H-13"
    executionId = "EXEC-SECRET-TEST"
    correlationId = "CORR-SECRET-TEST"
    tenantId = "TENANT-7H13-001"
    clientId = "CLIENT-7H13-001"
    projectId = "PROJECT-7H13-001"
    workerId = "MAYA"
    skillId = "CRM_AUTOMATION"
    taskId = "TASK-7H13-005"
    toolId = "CRM"
    action = "READ"
    mode = "SIMULATION"
    createdAt = "2026-01-01T00:00:00"
    security = [ordered]@{
        tenantIsolation = $true
        clientIsolation = $true
        projectIsolation = $true
        authorizationRequired = $true
        secretExposureToWorker = $false
    }
    financial = [ordered]@{
        approvalRequired = $false
        autonomousCommitAllowed = $false
    }
    metadata = [ordered]@{
        api_key = "TEST-SECRET"
    }
}

$SecretJson = $SecretObject | ConvertTo-Json -Depth 12

[System.IO.File]::WriteAllText(
    $SecretTestPath,
    $SecretJson,
    [System.Text.UTF8Encoding]::new($false)
)

if (-not (Test-Path -LiteralPath $SecretTestPath)) {

    Write-Host "FAIL : fichier de test secret non créé." -ForegroundColor Red
    $Failed++

}
else {

    & $Validator -ContextPath $SecretTestPath

    $SecretCode = $LASTEXITCODE

    if ($SecretCode -ne 0) {

        Write-Host "PASS : secret détecté et bloqué." -ForegroundColor Green
        $Passed++

    }
    else {

        Write-Host "FAIL : secret accepté." -ForegroundColor Red
        $Failed++

    }
}

if (Test-Path -LiteralPath $SecretTestPath) {
    Remove-Item -LiteralPath $SecretTestPath -Force
}

# ============================================================
# TEST 6
# ============================================================

Write-Host ""
Write-Host "TEST 6 : REGLE FINANCIERE"

if (
    -not [string]::IsNullOrWhiteSpace($ContextPath) -and
    (Test-Path -LiteralPath $ContextPath)
) {

    $ContextContent = Get-Content `
        -LiteralPath $ContextPath `
        -Raw `
        -Encoding UTF8

    if (
        $ContextContent -match '"autonomousCommitAllowed"\s*:\s*false'
    ) {

        Write-Host "PASS : finance autonome interdite." -ForegroundColor Green
        $Passed++

    }
    else {

        Write-Host "FAIL : règle financière absente." -ForegroundColor Red
        $Failed++

    }

}
else {

    Write-Host "FAIL : contexte principal absent." -ForegroundColor Red
    $Failed++

}

# ============================================================
# RESULTAT
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "              RESULTATS 7H-13" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "PASS : $Passed" -ForegroundColor Green
Write-Host "FAIL : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {

    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Context opérationnel." -ForegroundColor Green
    exit 0

}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1