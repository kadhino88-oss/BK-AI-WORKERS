$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$RuntimeDir = Join-Path $Root "core\runtime\execution-admission"
$RuntimePath = Join-Path $RuntimeDir "EXECUTION-ADMISSION-RUNTIME.ps1"

. $RuntimePath

$pass = 0
$fail = 0

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {
        & $Action
        Write-Host "PASS : $Name" -ForegroundColor Green
        $script:pass++
    }
    catch {
        Write-Host "FAIL : $Name" -ForegroundColor Red
        Write-Host "       $($_.Exception.Message)" -ForegroundColor Red
        $script:fail++
    }
}

Reset-AdmissionState

$config = Get-AdmissionConfig

Assert-Test "configuration Admission Gate valide" {
    if (-not $config.enabled) { throw "enabled invalide" }
    if (-not $config.admissionGateEnabled) { throw "gate invalide" }
    if (-not $config.readinessChecksEnabled) { throw "readiness invalide" }
}

Assert-Test "Admission Gate et readiness checks actifs" {
    if (-not $config.admissionGateEnabled) {
        throw "Admission Gate inactif."
    }

    if (-not $config.readinessChecksEnabled) {
        throw "Readiness checks inactifs."
    }
}

Assert-Test "mode strict et isolation tenant actifs" {
    if (-not $config.strictMode) {
        throw "strictMode inactif."
    }

    if (-not $config.requireTenantIsolation) {
        throw "tenant isolation inactive."
    }
}

Assert-Test "securite et LIVE correctement verrouilles" {
    if ($config.captureSecrets) {
        throw "captureSecrets active."
    }

    if ($config.capturePayloads) {
        throw "capturePayloads active."
    }

    if ($config.liveExecutionEnabled) {
        throw "LIVE doit rester désactivé."
    }
}

Assert-Test "execution A correctement admise en PENDING" {
    $r = New-AdmissionRecord -ExecutionId "A" -TenantId "TENANT-A"

    if ($r.AdmissionStatus -ne "PENDING") {
        throw "Statut inattendu."
    }

    if ($r.Ready) {
        throw "Execution ne doit pas être ready."
    }
}

Assert-Test "execution A correctement persistee" {
    $r = Get-ExecutionAdmission `
        -ExecutionId "A" `
        -TenantId "TENANT-A"

    if ($null -eq $r) {
        throw "Admission introuvable."
    }
}

Assert-Test "admission bloquee sans dependances terminees" {
    $r = Test-ExecutionAdmission `
        -ExecutionId "A" `
        -TenantId "TENANT-A" `
        -DependenciesCompleted:$false `
        -DeadlineValid:$true

    if ($r.AdmissionStatus -ne "BLOCKED") {
        throw "Admission devrait être bloquée."
    }

    if ($r.Reason -notmatch "DEPENDENCIES") {
        throw "Raison DEPENDENCIES absente."
    }
}

Assert-Test "admission bloquee si deadline invalide" {
    $r = Test-ExecutionAdmission `
        -ExecutionId "A" `
        -TenantId "TENANT-A" `
        -DependenciesCompleted:$true `
        -DeadlineValid:$false

    if ($r.AdmissionStatus -ne "BLOCKED") {
        throw "Admission devrait être bloquée."
    }

    if ($r.Reason -notmatch "DEADLINE") {
        throw "Raison DEADLINE absente."
    }
}

Assert-Test "admission autorisee quand toutes les conditions sont satisfaites" {
    $r = Test-ExecutionAdmission `
        -ExecutionId "A" `
        -TenantId "TENANT-A" `
        -DependenciesCompleted:$true `
        -DeadlineValid:$true

    if ($r.AdmissionStatus -ne "ADMITTED") {
        throw "Admission non autorisée."
    }

    if (-not $r.Ready) {
        throw "Execution devrait être READY."
    }

    if (-not $r.SecurityReady) {
        throw "SecurityReady invalide."
    }

    if (-not $r.DependenciesReady) {
        throw "DependenciesReady invalide."
    }

    if (-not $r.DeadlineReady) {
        throw "DeadlineReady invalide."
    }
}

Assert-Test "lecture tenant correctement isolee" {
    $r = Get-ExecutionAdmission `
        -ExecutionId "A" `
        -TenantId "TENANT-B"

    if ($null -ne $r) {
        throw "Lecture cross-tenant autorisée."
    }
}

Assert-Test "execution inconnue correctement bloquee" {
    $thrown = $false

    try {
        Test-ExecutionAdmission `
            -ExecutionId "UNKNOWN" `
            -TenantId "TENANT-A" `
            -DependenciesCompleted:$true `
            -DeadlineValid:$true
    }
    catch {
        $thrown = $true
    }

    if (-not $thrown) {
        throw "Execution inconnue non bloquée."
    }
}

Assert-Test "ExecutionId vide correctement bloquee" {
    $thrown = $false

    try {
        New-AdmissionRecord `
            -ExecutionId "" `
            -TenantId "TENANT-A"
    }
    catch {
        $thrown = $true
    }

    if (-not $thrown) {
        throw "ExecutionId vide acceptée."
    }
}

Assert-Test "TenantId vide correctement bloquee" {
    $thrown = $false

    try {
        New-AdmissionRecord `
            -ExecutionId "X" `
            -TenantId ""
    }
    catch {
        $thrown = $true
    }

    if (-not $thrown) {
        throw "TenantId vide accepté."
    }
}

Assert-Test "contexte newline correctement bloque" {
    $thrown = $false

    try {
        New-AdmissionRecord `
            -ExecutionId "X`nBAD" `
            -TenantId "TENANT-A"
    }
    catch {
        $thrown = $true
    }

    if (-not $thrown) {
        throw "Contexte newline accepté."
    }
}

Assert-Test "admission duplicate correctement bloquee" {
    $thrown = $false

    try {
        New-AdmissionRecord `
            -ExecutionId "A" `
            -TenantId "TENANT-A"
    }
    catch {
        $thrown = $true
    }

    if (-not $thrown) {
        throw "Duplicate accepté."
    }
}

Assert-Test "etat Admission sans secret ni payload" {
    $raw = Get-Content `
        -LiteralPath (Join-Path $RuntimeDir "state\admissions.json") `
        -Raw

    if ($raw -match "password|token|secret|payload|authorization") {
        throw "Donnée sensible détectée."
    }
}

Assert-Test "LIVE execution reste desactive" {
    if ($config.liveExecutionEnabled) {
        throw "LIVE activé."
    }

    $r = Get-ExecutionAdmission `
        -ExecutionId "A" `
        -TenantId "TENANT-A"

    if ($r.LiveAllowed) {
        throw "LiveAllowed ne doit jamais être true."
    }
}

Assert-Test "reset Admission Gate correctement execute" {
    Reset-AdmissionState

    $state = Get-AdmissionState

    if ($state.Count -ne 0) {
        throw "Reset incomplet."
    }
}

Write-Host ""
Write-Host "RESULTATS 7H-46" -ForegroundColor Cyan
Write-Host "PASS : $pass" -ForegroundColor Green
Write-Host "FAIL : $fail" -ForegroundColor Red

if ($fail -eq 0) {
    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Admission / Readiness Gate operationnel." -ForegroundColor Green
    exit 0
}
else {
    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
    exit 1
}
