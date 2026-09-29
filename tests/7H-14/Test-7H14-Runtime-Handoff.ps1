$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Builder = "$Root\core\runtime\execution-context\New-Execution-Context.ps1"
$Bridge = "$Root\core\runtime\EXECUTION-CONTEXT-HANDOFF.ps1"
$Validator = "$Root\core\runtime\Validate-Execution-HANDOFF.ps1"
$TestDir = "$Root\tests\7H-14"

$Passed = 0
$Failed = 0

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       BK-AI-WORKERS - PHASE 7H-14" -ForegroundColor Cyan
Write-Host "       RUNTIME CONTEXT HANDOFF" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

foreach ($File in @($Builder,$Bridge,$Validator)) {

    if (-not (Test-Path -LiteralPath $File)) {
        Write-Host "FICHIER ABSENT : $File" -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# TEST 1 : CREATION CONTEXTE
# ============================================================

Write-Host "TEST 1 : CREATION EXECUTION CONTEXT"

$Build = & $Builder `
    -TenantId "TENANT-7H14-001" `
    -ClientId "CLIENT-7H14-001" `
    -ProjectId "PROJECT-7H14-001" `
    -WorkerId "MAYA" `
    -SkillId "CRM_AUTOMATION" `
    -TaskId "TASK-7H14-001" `
    -ToolId "CRM" `
    -Action "READ" `
    -Mode "SIMULATION"

$ContextPath = [string]$Build.path

if (
    -not [string]::IsNullOrWhiteSpace($ContextPath) -and
    (Test-Path -LiteralPath $ContextPath)
) {

    Write-Host "PASS" -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 2 : HANDOFF
# ============================================================

Write-Host ""
Write-Host "TEST 2 : HANDOFF CONTEXTE VERS RUNTIME"

try {

    $HandoffResult = & $Bridge `
        -ContextPath $ContextPath `
        -ErrorAction Stop

    if (
        $null -ne $HandoffResult -and
        $HandoffResult.handoffAccepted -eq $true
    ) {

        Write-Host "PASS : handoff accepté." -ForegroundColor Green
        $Passed++

    }
    else {

        Write-Host "FAIL : handoff refusé." -ForegroundColor Red
        $Failed++
    }

}
catch {

    Write-Host "FAIL : $($_.Exception.Message)" -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 3 : IDENTITE PRESERVEE
# ============================================================

Write-Host ""
Write-Host "TEST 3 : IDENTITE PRESERVEE"

if (
    $HandoffResult.executionId -eq $Build.executionId -and
    $HandoffResult.correlationId -eq $Build.correlationId
) {

    Write-Host "PASS : ExecutionId / CorrelationId conservés." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL : identité modifiée." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 4 : VALIDATION HANDOFF
# ============================================================

Write-Host ""
Write-Host "TEST 4 : VALIDATION DU HANDOFF"

$HandoffValidationPath = "$TestDir\HANDOFF-VALIDATION-TEST.json"

$HandoffJson = $HandoffResult.handoff | ConvertTo-Json -Depth 12

[System.IO.File]::WriteAllText(
    $HandoffValidationPath,
    $HandoffJson,
    [System.Text.UTF8Encoding]::new($false)
)

& $Validator -ContextPath $HandoffValidationPath

if ($LASTEXITCODE -eq 0) {

    Write-Host "PASS : handoff valide." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL : handoff invalide." -ForegroundColor Red
    $Failed++
}

Remove-Item `
    -LiteralPath $HandoffValidationPath `
    -Force `
    -ErrorAction SilentlyContinue

# ============================================================
# TEST 5 : EXECUTION LIVE NON AUTORISEE
# ============================================================

Write-Host ""
Write-Host "TEST 5 : EXECUTION NON AUTORISEE PAR DEFAUT"

if ($HandoffResult.handoff.runtime.executionAllowed -eq $false) {

    Write-Host "PASS : Runtime ne peut pas exécuter automatiquement." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL : executionAllowed devrait être FALSE." -ForegroundColor Red
    $Failed++
}

# ============================================================
# TEST 6 : FINANCE
# ============================================================

Write-Host ""
Write-Host "TEST 6 : FINANCE AUTONOME"

if (
    $HandoffResult.handoff.financial.autonomousCommitAllowed -eq $false
) {

    Write-Host "PASS : finance autonome interdite." -ForegroundColor Green
    $Passed++

}
else {

    Write-Host "FAIL : règle financière incorrecte." -ForegroundColor Red
    $Failed++
}

# ============================================================
# RESULTAT
# ============================================================

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "              RESULTATS 7H-14" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "PASS : $Passed" -ForegroundColor Green
Write-Host "FAIL : $Failed" -ForegroundColor Red
Write-Host ""

if ($Failed -eq 0) {

    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Runtime Context Handoff opérationnel." -ForegroundColor Green
    exit 0

}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1