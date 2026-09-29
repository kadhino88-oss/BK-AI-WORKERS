$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Conflict-Closure-Guard.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-39 REVOCATION CONFLICT CLOSURE & IMMUTABLE GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-ConflictClosure

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

$config = Get-ConflictClosureConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 closure module enabled" $t01

$t02 = $config.closureEnabled -eq $true
Add-Test "02 closure enabled" $t02

$t03 = $config.immutableClosureEnabled -eq $true
Add-Test "03 immutable closure enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireResolvedConflict -eq $true
Add-Test "05 resolved conflict required" $t05

$t06 = $config.requireRevokedResolution -eq $true
Add-Test "06 revoked resolution required" $t06

$t07 = $config.requireBlockedExecution -eq $true
Add-Test "07 blocked execution required" $t07

$t08 = $config.requireTenantBinding -eq $true
Add-Test "08 tenant binding required" $t08

$t09 = $config.requireExecutionBinding -eq $true
Add-Test "09 execution binding required" $t09

$t10 = $config.requireIntegrityHash -eq $true
Add-Test "10 integrity hash required" $t10

$t11 = $config.blockReopen -eq $true
Add-Test "11 reopen blocked" $t11

$t12 = $config.blockMutation -eq $true
Add-Test "12 mutation blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Close-ResolvedRevocationConflict -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 conflict closure function exists" $t13

$cmd14 = Get-Command Test-ConflictClosure -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 closure validator exists" $t14

$cmd15 = Get-Command Test-ConflictClosureIntegrity -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 closure integrity validator exists" $t15

$cmd16 = Get-Command Test-ConflictClosureIsolation -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 closure isolation validator exists" $t16

# ============================================================
# CONTROLLED RESOLVED CONFLICT
# ============================================================

$ConflictId = "CONFLICT-8A39-001"
$EnforcementId = "ENF-8A39-001"
$RecoveryId = "REC-8A39-001"
$TenantId = "TENANT-001"
$ExecutionId = "EXEC-8A39-001"

$closure = Close-ResolvedRevocationConflict `
    -ConflictId $ConflictId `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -TenantId $TenantId `
    -ExecutionId $ExecutionId `
    -ResolvedEnforcement "REVOKED" `
    -ResolvedConsumption "REVOKED" `
    -ResolvedAuthorization "REVOKED" `
    -ResolvedExecution "BLOCKED" `
    -ResolutionStatus "RESOLVED"

$records = @(Get-ConflictClosureRecords)

# ============================================================
# 17-24
# ============================================================

$t17 = $closure.Allowed -eq $true
Add-Test "17 resolved conflict closed" $t17

$t18 = (
    $closure.Decision -eq "BLOCK" -and
    $closure.ClosureStatus -eq "CLOSED"
)
Add-Test "18 closed conflict remains blocked" $t18

$t19 = (
    $records.Count -eq 1 -and
    $records[0].ResolutionStatus -eq "RESOLVED"
)
Add-Test "19 resolved status persisted" $t19

$t20 = (
    $records[0].ResolvedEnforcement -eq "REVOKED" -and
    $records[0].ResolvedConsumption -eq "REVOKED" -and
    $records[0].ResolvedAuthorization -eq "REVOKED" -and
    $records[0].ResolvedExecution -eq "BLOCKED"
)
Add-Test "20 closed resolution state coherent" $t20

$t21 = (
    $records[0].Immutable -eq $true -and
    $records[0].PermanentClosure -eq $true
)
Add-Test "21 permanent immutable closure enabled" $t21

$t22 = (
    $records[0].ReopenAllowed -eq $false -and
    $records[0].MutationAllowed -eq $false -and
    $records[0].ReactivationAllowed -eq $false -and
    $records[0].ResolutionRewriteAllowed -eq $false
)
Add-Test "22 reopen mutation reactivation rewrite blocked" $t22

$validation = Test-ConflictClosure `
    -ClosureId $closure.ClosureId

$t23 = (
    $validation.Allowed -eq $true -and
    $validation.Decision -eq "BLOCK" -and
    $validation.Code -eq "CONFLICT_CLOSURE_VALID"
)
Add-Test "23 closure validation succeeds" $t23

$integrity = Test-ConflictClosureIntegrity

$isolation = Test-ConflictClosureIsolation `
    -ClosureId $closure.ClosureId `
    -TenantId $TenantId `
    -ExecutionId $ExecutionId

$rawState = Get-Content `
    -LiteralPath "$Root\state\closures.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "CONFLICT_CLOSURE_INTEGRITY_VALID" -and
    $isolation.Allowed -eq $true -and
    $isolation.Code -eq "CLOSURE_SCOPE_VALID" -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 closure integrity isolation and secrets protection valid" $t24

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
Write-Host "RESULTAT 8A-39 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-39 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-39 : ECHEC - NE PAS PASSER A 8A-40" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
