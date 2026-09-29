$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$Dir = Join-Path $Root "core\runtime\concurrency"
$LockDir = Join-Path $Dir "locks"

$ConfigPath = Join-Path `
    $Dir `
    "CONCURRENCY-CONFIG.json"

$Validator = Join-Path `
    $Dir `
    "Validate-Concurrency.ps1"

$Runtime = Join-Path `
    $Dir `
    "CONCURRENCY-RUNTIME.ps1"

# Nettoyage des locks de test
if (Test-Path -LiteralPath $LockDir) {
    Get-ChildItem `
        -LiteralPath $LockDir `
        -Filter "*.json" `
        -ErrorAction SilentlyContinue |
        Remove-Item -Force
}

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
Write-Host "7H-29 - EXECUTION CONCURRENCY & LOCK MANAGER"
Write-Host "============================================="
Write-Host ""

# ============================================================
# TEST 1
# ============================================================

try {
    & $Validator $ConfigPath | Out-Host

    if ($LASTEXITCODE -eq 0) {
        Pass-Test "Concurrency Config valide"
    }
    else {
        Fail-Test "Concurrency Config invalide"
    }
}
catch {
    Fail-Test "validation Concurrency"
}

. $Runtime

# ============================================================
# TEST 2
# Lock key
# ============================================================

$key = New-ExecutionLockKey `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK"

if (
    $key.status -eq "CREATED" -and
    $key.lockKey -match '^LOCK-[a-f0-9]{64}$'
) {
    Pass-Test "clé de concurrence correctement générée"
}
else {
    Fail-Test "clé de concurrence incorrecte"
}

# ============================================================
# TEST 3
# Acquisition
# ============================================================

$lock1 = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-001" `
    -OwnerId "ORCHESTRATOR-001" `
    -LockSeconds 120

if (
    $lock1.status -eq "ACQUIRED" -and
    (Test-Path -LiteralPath $lock1.lockPath)
) {
    Pass-Test "lock correctement acquis"
}
else {
    Fail-Test "lock non acquis"
}

# ============================================================
# TEST 4
# Concurrent execution
# ============================================================

$lock2 = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-002" `
    -OwnerId "ORCHESTRATOR-002" `
    -LockSeconds 120

if (
    $lock2.status -eq "LOCKED" -and
    $lock2.reason -eq "CONCURRENT_EXECUTION" -and
    $lock2.activeExecutionId -eq "EXEC-7H29-001"
) {
    Pass-Test "exécution concurrente correctement bloquée"
}
else {
    Fail-Test "exécution concurrente non bloquée"
}

# ============================================================
# TEST 5
# Mauvais owner
# ============================================================

$releaseBad = Release-ExecutionLock `
    -LockPath $lock1.lockPath `
    -ExecutionId "EXEC-7H29-001" `
    -OwnerId "WRONG-OWNER"

if (
    $releaseBad.status -eq "BLOCKED" -and
    $releaseBad.reason -eq "LOCK_OWNER_MISMATCH"
) {
    Pass-Test "mauvais owner correctement bloqué"
}
else {
    Fail-Test "mauvais owner non bloqué"
}

# ============================================================
# TEST 6
# Release correct
# ============================================================

$release = Release-ExecutionLock `
    -LockPath $lock1.lockPath `
    -ExecutionId "EXEC-7H29-001" `
    -OwnerId "ORCHESTRATOR-001"

if (
    $release.status -eq "RELEASED" -and
    -not (Test-Path -LiteralPath $lock1.lockPath)
) {
    Pass-Test "lock correctement libéré"
}
else {
    Fail-Test "lock non libéré"
}

# ============================================================
# TEST 7
# Nouvelle acquisition après release
# ============================================================

$lock3 = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-003" `
    -OwnerId "ORCHESTRATOR-003" `
    -LockSeconds 120

if (
    $lock3.status -eq "ACQUIRED" -and
    $lock3.executionId -eq "EXEC-7H29-003"
) {
    Pass-Test "nouvelle acquisition après release autorisée"
}
else {
    Fail-Test "nouvelle acquisition après release refusée"
}

# ============================================================
# TEST 8
# Client isolation
# ============================================================

$client2 = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-002" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-004" `
    -OwnerId "ORCHESTRATOR-004" `
    -LockSeconds 120

if (
    $client2.status -eq "ACQUIRED"
) {
    Pass-Test "client différent isolé"
}
else {
    Fail-Test "isolation client incorrecte"
}

# ============================================================
# TEST 9
# Tenant isolation
# ============================================================

$tenant2 = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-002" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-005" `
    -OwnerId "ORCHESTRATOR-005" `
    -LockSeconds 120

if (
    $tenant2.status -eq "ACQUIRED"
) {
    Pass-Test "tenant différent isolé"
}
else {
    Fail-Test "isolation tenant incorrecte"
}

# ============================================================
# TEST 10
# Project isolation
# ============================================================

$project2 = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-002" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-006" `
    -OwnerId "ORCHESTRATOR-006" `
    -LockSeconds 120

if (
    $project2.status -eq "ACQUIRED"
) {
    Pass-Test "projet différent isolé"
}
else {
    Fail-Test "isolation projet incorrecte"
}

# ============================================================
# TEST 11
# Secret absent
# ============================================================

$lockContent = Get-Content `
    -LiteralPath $lock3.lockPath `
    -Raw `
    -Encoding UTF8

if (
    $lockContent -notmatch '(?i)api.?key' -and
    $lockContent -notmatch '(?i)access.?token' -and
    $lockContent -notmatch '(?i)password' -and
    $lockContent -notmatch '(?i)client.?secret' -and
    $lockContent -notmatch '(?i)private.?key'
) {
    Pass-Test "lock sans secret"
}
else {
    Fail-Test "secret détecté dans le lock"
}

# ============================================================
# TEST 12
# Contexte incomplet
# ============================================================

$bad = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-007" `
    -OwnerId "ORCHESTRATOR-007" `
    -LockSeconds 120

if (
    $bad.status -eq "BLOCKED" -and
    $bad.reason -eq "CONTEXT_INCOMPLETE" -and
    $bad.field -eq "ProjectId"
) {
    Pass-Test "contexte incomplet bloqué"
}
else {
    Fail-Test "contexte incomplet non bloqué"
}

# ============================================================
# TEST 13
# Durée trop faible
# ============================================================

$bad = Acquire-ExecutionLock `
    -ConfigPath $ConfigPath `
    -LockDirectory $LockDir `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ConnectorId "crm.controlled" `
    -Operation "CREATE_TASK" `
    -ExecutionId "EXEC-7H29-008" `
    -OwnerId "ORCHESTRATOR-008" `
    -LockSeconds 1

if (
    $bad.status -eq "BLOCKED" -and
    $bad.reason -eq "LOCK_DURATION_TOO_LOW"
) {
    Pass-Test "durée de lock trop faible bloquée"
}
else {
    Fail-Test "durée trop faible non bloquée"
}

# ============================================================
# TEST 14
# Stale lock
# ============================================================

$staleLock = [pscustomobject]@{
    lockKey = "LOCK-STALE"
    executionId = "EXEC-STALE"
    expiresAtUnix = 1
}

$stale = Test-ExecutionLockStale `
    -Lock $staleLock `
    -CurrentUnixTime ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())

if (
    $stale.status -eq "STALE" -and
    $stale.stale -eq $true
) {
    Pass-Test "stale lock correctement détecté"
}
else {
    Fail-Test "stale lock non détecté"
}

# ============================================================
# CLEANUP
# ============================================================

foreach ($lock in @(
    $lock3,
    $client2,
    $tenant2,
    $project2
)) {
    if (
        $null -ne $lock -and
        $lock.status -eq "ACQUIRED"
    ) {
        Release-ExecutionLock `
            -LockPath $lock.lockPath `
            -ExecutionId $lock.executionId `
            -OwnerId $lock.ownerId | Out-Null
    }
}

Write-Host ""
Write-Host "RESULTATS 7H-29"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"
Write-Host ""

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Concurrency & Lock Manager opérationnel."
    exit 0
}

Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
exit 1