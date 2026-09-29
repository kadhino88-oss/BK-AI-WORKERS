$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$RuntimePath = Join-Path $Root "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " ACTIVE CONTEXT SECURITY TEST"
Write-Host " PHASE 5D"
Write-Host "============================================"
Write-Host ""

$activeFiles = Get-ChildItem $RuntimePath -Filter "ACTIVE-*.json" -File

if ($activeFiles.Count -eq 0) {
    Write-Host "RESULTAT : FAIL"
    Write-Host "RAISON : AUCUN CONTEXTE ACTIF"
    exit 10
}

$passed = 0
$failed = 0

foreach ($file in $activeFiles) {

    Write-Host "TEST : $($file.Name)"
    Write-Host ""

    try {
        $context = Get-Content $file.FullName -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "JSON : FAIL"
        $failed++
        continue
    }

    $ok = $true

    if ([string]::IsNullOrWhiteSpace($context.context_id)) {
        Write-Host "CONTEXT ID : FAIL"
        $ok = $false
    }
    else {
        Write-Host "CONTEXT ID : OK"
    }

    if ([string]::IsNullOrWhiteSpace($context.client.id)) {
        Write-Host "CLIENT : FAIL"
        $ok = $false
    }
    else {
        Write-Host "CLIENT : $($context.client.id)"
    }

    if ([string]::IsNullOrWhiteSpace($context.project.id)) {
        Write-Host "PROJECT : FAIL"
        $ok = $false
    }
    else {
        Write-Host "PROJECT : $($context.project.id)"
    }

    if ([string]::IsNullOrWhiteSpace($context.worker.id)) {
        Write-Host "WORKER : FAIL"
        $ok = $false
    }
    else {
        Write-Host "WORKER : $($context.worker.id)"
    }

    if ([string]::IsNullOrWhiteSpace($context.task.id)) {
        Write-Host "TASK : FAIL"
        $ok = $false
    }
    else {
        Write-Host "TASK : $($context.task.id)"
    }

    if ($context.permissions.read -eq $true) {
        Write-Host "READ : AUTORISE"
    }
    else {
        Write-Host "READ : FAIL"
        $ok = $false
    }

    if ($context.permissions.write -eq $true) {
        Write-Host "WRITE : AUTORISE"
    }
    else {
        Write-Host "WRITE : FAIL"
        $ok = $false
    }

    if ($context.permissions.external_actions -eq $false) {
        Write-Host "EXTERNAL ACTIONS : BLOQUEES"
    }
    else {
        Write-Host "EXTERNAL ACTIONS : FAIL"
        $ok = $false
    }

    if ($context.permissions.financial_actions -eq $false) {
        Write-Host "FINANCIAL ACTIONS : BLOQUEES"
    }
    else {
        Write-Host "FINANCIAL ACTIONS : FAIL"
        $ok = $false
    }

    Write-Host ""

    if ($ok) {
        Write-Host "RESULTAT : PASS"
        $passed++
    }
    else {
        Write-Host "RESULTAT : FAIL"
        $failed++
    }

    Write-Host ""
}

Write-Host "============================================"
Write-Host " RESULTAT FINAL"
Write-Host "============================================"
Write-Host ""

Write-Host "CONTEXTES TESTES : $($activeFiles.Count)"
Write-Host "TESTS PASSES     : $passed"
Write-Host "TESTS ECHOUES    : $failed"
Write-Host ""

if ($failed -eq 0) {
    Write-Host "ACTIVE CONTEXT : SECURE"
    Write-Host "PHASE 5D : VALIDEE"
    exit 0
}

Write-Host "ACTIVE CONTEXT : FAIL"
exit 20