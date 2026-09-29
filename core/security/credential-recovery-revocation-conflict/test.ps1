$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Revocation-Conflict-Guard.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-38 REVOCATION CONFLICT & DRIFT RESOLUTION GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-RevocationConflict

$results = @()

function Add-Test {

    param(
        [string]$Name,
        [bool]$Passed
    )

    if ($Passed -eq $true) {

        Write-Host "[PASS] $Name" -ForegroundColor Green

        $script:results += [pscustomobject]@{
            Test = $Name
            Result = "PASS"
        }
    }
    else {

        Write-Host "[FAIL] $Name" -ForegroundColor Red

        $script:results += [pscustomobject]@{
            Test = $Name
            Result = "FAIL"
        }
    }
}

$config = Get-RevocationConflictConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 conflict guard enabled" $t01

$t02 = $config.conflictDetectionEnabled -eq $true
Add-Test "02 conflict detection enabled" $t02

$t03 = $config.driftDetectionEnabled -eq $true
Add-Test "03 drift detection enabled" $t03

$t04 = $config.resolutionEnabled -eq $true
Add-Test "04 resolution enabled" $t04

$t05 = $config.failClosed -eq $true
Add-Test "05 fail closed enabled" $t05

$t06 = $config.requireSameEnforcementId -eq $true
Add-Test "06 enforcement identity required" $t06

$t07 = $config.requireSameRecoveryId -eq $true
Add-Test "07 recovery identity required" $t07

$t08 = $config.requireSameTenantId -eq $true
Add-Test "08 tenant identity required" $t08

$t09 = $config.requireSameExecutionId -eq $true
Add-Test "09 execution identity required" $t09

$t10 = $config.blockConflicts -eq $true
Add-Test "10 conflicts blocked" $t10

$t11 = $config.blockStateDrift -eq $true
Add-Test "11 state drift blocked" $t11

$t12 = $config.deterministicResolution -eq $true
Add-Test "12 deterministic resolution enabled" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-RevocationConflict -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 conflict registration exists" $t13

$cmd14 = Get-Command Resolve-RevocationConflict -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 conflict resolution exists" $t14

$cmd15 = Get-Command Test-RevocationConflictResolution -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 resolution validator exists" $t15

$cmd16 = Get-Command Test-RevocationConflictIntegrity -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 conflict integrity validator exists" $t16

# ============================================================
# CONTROLLED CONFLICT
# ============================================================

$EnforcementId = "ENF-8A38-001"
$RecoveryId = "REC-8A38-001"
$TenantId = "TENANT-001"
$ExecutionId = "EXEC-8A38-001"

$source = Register-RevocationConflict `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -TenantId $TenantId `
    -ExecutionId $ExecutionId `
    -StateAEnforcement "ACTIVE" `
    -StateAConsumption "AUTHORIZED" `
    -StateAAuthorization "AUTHORIZED" `
    -StateAExecution "AUTHORIZED" `
    -StateBEnforcement "REVOKED" `
    -StateBConsumption "REVOKED" `
    -StateBAuthorization "REVOKED" `
    -StateBExecution "BLOCKED"

$recordsBefore = @(Get-RevocationConflictRecords)

# ============================================================
# 17-19 DETECTION
# ============================================================

$t17 = $source.Allowed -eq $true
Add-Test "17 conflict source registered" $t17

$t18 = (
    $source.ConflictDetected -eq $true -and
    $recordsBefore.Count -eq 1
)
Add-Test "18 state divergence detected" $t18

$t19 = $recordsBefore[0].ConflictType -eq "STATE_DIVERGENCE"
Add-Test "19 conflict type correctly classified" $t19

# ============================================================
# RESOLUTION
# ============================================================

$resolution = Resolve-RevocationConflict `
    -ConflictId $source.ConflictId

$recordsAfter = @(Get-RevocationConflictRecords)

# ============================================================
# 20-24
# ============================================================

$t20 = (
    $resolution.Allowed -eq $true -and
    $resolution.Code -eq "REVOCATION_CONFLICT_RESOLVED"
)
Add-Test "20 conflict resolution completed" $t20

$t21 = (
    $recordsAfter[0].ResolvedEnforcement -eq "REVOKED" -and
    $recordsAfter[0].ResolvedConsumption -eq "REVOKED" -and
    $recordsAfter[0].ResolvedAuthorization -eq "REVOKED" -and
    $recordsAfter[0].ResolvedExecution -eq "BLOCKED"
)
Add-Test "21 revoked state wins deterministically" $t21

$t22 = (
    $recordsAfter[0].ResolutionStatus -eq "RESOLVED" -and
    $recordsAfter[0].ResolutionDecision -eq "BLOCK" -and
    $recordsAfter[0].SourceRevoked -eq $true -and
    $recordsAfter[0].ExecutionBlocked -eq $true
)
Add-Test "22 resolved state remains fail closed" $t22

$validation = Test-RevocationConflictResolution `
    -ConflictId $source.ConflictId

$t23 = (
    $validation.Allowed -eq $true -and
    $validation.Decision -eq "BLOCK" -and
    $validation.Code -eq "REVOCATION_CONFLICT_RESOLUTION_VALID"
)
Add-Test "23 conflict resolution validated" $t23

$integrity = Test-RevocationConflictIntegrity

$isolation = Test-RevocationConflictIsolation `
    -ConflictId $source.ConflictId `
    -TenantId $TenantId `
    -ExecutionId $ExecutionId

$rawState = Get-Content `
    -LiteralPath "$Root\state\conflicts.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "REVOCATION_CONFLICT_INTEGRITY_VALID" -and
    $isolation.Allowed -eq $true -and
    $isolation.Code -eq "CONFLICT_SCOPE_VALID" -and
    $recordsAfter[0].ReactivationAllowed -eq $false -and
    $recordsAfter[0].ReopenAllowed -eq $false -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "24 conflict integrity isolation and secrets protection valid" $t24

# ============================================================
# FINAL STRICT
# ============================================================

$total = $results.Count

$pass = @(
    $results |
    Where-Object {
        $_.Result -eq "PASS"
    }
).Count

$fail = @(
    $results |
    Where-Object {
        $_.Result -eq "FAIL"
    }
).Count

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : $total" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-38 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-38 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-38 : ECHEC - NE PAS PASSER A 8A-39" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
