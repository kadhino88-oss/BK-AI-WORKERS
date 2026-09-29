$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Router = Join-Path `
    $Root `
    "core\tools\TOOL-ROUTER.ps1"

$AuditPath = Join-Path `
    $Root `
    "core\logging\audit\CAPABILITY-AUDIT.jsonl"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       7H-12 TOOL ROUTER ENFORCEMENT" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $Router)) {
    throw "TOOL-ROUTER.ps1 introuvable."
}

$BeforeAudit = 0

if (Test-Path -LiteralPath $AuditPath) {
    $BeforeAudit = @(Get-Content -LiteralPath $AuditPath -Encoding UTF8).Count
}

$Passed = 0
$Failed = 0

# ============================================================
# TEST 1
# ============================================================

Write-Host "TEST 1 : MAYA / CRM / READ / TASKID" -ForegroundColor White

$r1 = & $Router `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ClientId "CLIENT-7H12" `
    -ProjectId "PROJECT-7H12" `
    -TaskId "TASK-7H12-001" `
    -Mode "SIMULATION"

$d1 = $r1.authorization

if ($null -eq $d1) {
    $d1 = $r1
}

if ($d1.decision -eq "AUTHORIZED") {

    Write-Host "PASS : capability autorisée." -ForegroundColor Green

    if ($r1.executionStatus -eq "DELEGATED_SUCCESS") {
        Write-Host "PASS : delegation legacy réussie." -ForegroundColor Green
    }
    elseif ($r1.executionStatus -eq "LEGACY_PREREQUISITE_MISSING") {
        Write-Host "INFO : prérequis legacy supplémentaire détecté." -ForegroundColor Yellow
    }
    elseif ($r1.executionStatus -eq "DELEGATION_FAILED") {
        Write-Host "INFO : capability OK mais délégation legacy en erreur." -ForegroundColor Yellow
    }
    else {
        Write-Host "INFO : autorisation validée sans délégation." -ForegroundColor Yellow
    }

    $Passed++
}
else {
    Write-Host "FAIL : capability non autorisée." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 2
# ============================================================

Write-Host ""
Write-Host "TEST 2 : SAM / CRM / UPDATE" -ForegroundColor White

$r2 = & $Router `
    -WorkerId "SAM" `
    -SkillId "SECURITY" `
    -ToolId "CRM" `
    -Action "UPDATE" `
    -ClientId "CLIENT-7H12" `
    -ProjectId "PROJECT-7H12" `
    -TaskId "TASK-7H12-002" `
    -Mode "SIMULATION"

if ($r2.decision -eq "DENIED") {
    Write-Host "PASS : capability refusée." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL : attendu DENIED." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 3
# ============================================================

Write-Host ""
Write-Host "TEST 3 : FINANCIAL COMMIT" -ForegroundColor White

$r3 = & $Router `
    -WorkerId "MAYA" `
    -SkillId "STRATEGIE" `
    -ToolId "PAYMENTS" `
    -Action "FINANCIAL_COMMIT" `
    -ClientId "CLIENT-7H12" `
    -ProjectId "PROJECT-7H12" `
    -TaskId "TASK-7H12-003" `
    -Mode "SIMULATION"

if ($r3.decision -eq "NEEDS_HUMAN") {
    Write-Host "PASS : validation humaine requise." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL : attendu NEEDS_HUMAN." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 4
# ============================================================

Write-Host ""
Write-Host "TEST 4 : CLIENT VIDE" -ForegroundColor White

$r4 = & $Router `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ClientId "" `
    -ProjectId "PROJECT-7H12" `
    -TaskId "TASK-7H12-004" `
    -Mode "SIMULATION"

if ($r4.status -eq "BLOCKED") {
    Write-Host "PASS : client vide bloqué." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL : client vide non bloqué." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 5
# ============================================================

Write-Host ""
Write-Host "TEST 5 : PROJET VIDE" -ForegroundColor White

$r5 = & $Router `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ClientId "CLIENT-7H12" `
    -ProjectId "" `
    -TaskId "TASK-7H12-005" `
    -Mode "SIMULATION"

if ($r5.status -eq "BLOCKED") {
    Write-Host "PASS : projet vide bloqué." -ForegroundColor Green
    $Passed++
}
else {
    Write-Host "FAIL : projet vide non bloqué." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 6 : TASKID ABSENT
# ============================================================

Write-Host ""
Write-Host "TEST 6 : TASKID ABSENT DU NOUVEAU ROUTER" -ForegroundColor White

$r6 = & $Router `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -ToolId "CRM" `
    -Action "READ" `
    -ClientId "CLIENT-7H12" `
    -ProjectId "PROJECT-7H12" `
    -Mode "SIMULATION"

if (
    $r6.executionStatus -eq "LEGACY_PREREQUISITE_MISSING"
) {

    Write-Host "PASS : aucune invite interactive ; délégation proprement bloquée." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL : comportement attendu non obtenu." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 7 : AUDIT
# ============================================================

Write-Host ""
Write-Host "TEST 7 : AUDIT" -ForegroundColor White

if (Test-Path -LiteralPath $AuditPath) {

    $AfterAudit = @(Get-Content -LiteralPath $AuditPath -Encoding UTF8)

    $Created = $AfterAudit.Count - $BeforeAudit

    if ($Created -ge 6) {
        Write-Host "PASS : $Created décision(s) auditée(s)." -ForegroundColor Green
        $Passed++
    }
    else {
        Write-Host "FAIL : audit insuffisant." -ForegroundColor Red
        $Failed++
    }

}
else {

    Write-Host "FAIL : fichier audit absent." -ForegroundColor Red
    $Failed++
}

# ============================================================
# RESULTAT
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "              RESULTATS 7H-12" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "PASS : $Passed" -ForegroundColor Green
Write-Host "FAIL : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {

    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Tool Router sécurisé, non interactif et audité." -ForegroundColor Green
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1