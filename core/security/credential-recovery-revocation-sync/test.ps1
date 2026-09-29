$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Revocation-Propagation-Sync.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-37 REVOCATION PROPAGATION & CROSS-MODULE SYNC" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-RevocationSync

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

$config = Get-RevocationSyncConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 synchronization module enabled" $t01

$t02 = $config.propagationEnabled -eq $true
Add-Test "02 propagation enabled" $t02

$t03 = $config.synchronizationEnabled -eq $true
Add-Test "03 synchronization enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireSourceRevocation -eq $true
Add-Test "05 source revocation required" $t05

$t06 = $config.requireEnforcementSync -eq $true
Add-Test "06 enforcement sync required" $t06

$t07 = $config.requireConsumptionSync -eq $true
Add-Test "07 consumption sync required" $t07

$t08 = $config.requireAuthorizationSync -eq $true
Add-Test "08 authorization sync required" $t08

$t09 = $config.requireExecutionSync -eq $true
Add-Test "09 execution sync required" $t09

$t10 = $config.requireTenantBinding -eq $true
Add-Test "10 tenant binding required" $t10

$t11 = $config.blockPartialPropagation -eq $true
Add-Test "11 partial propagation blocked" $t11

$t12 = $config.blockStateDrift -eq $true
Add-Test "12 state drift blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-RevocationSource -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 revocation source registration exists" $t13

$cmd14 = Get-Command Invoke-RevocationPropagation -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 propagation function exists" $t14

$cmd15 = Get-Command Test-RevocationPropagation -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 propagation validator exists" $t15

$cmd16 = Get-Command Test-RevocationSynchronizationIntegrity -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 synchronization integrity validator exists" $t16

# ============================================================
# CONTROLLED REVOCATION CHAIN
# ============================================================

$EnforcementId = "ENF-8A37-001"
$RecoveryId = "REC-8A37-001"
$ConsumptionId = "CONSUME-8A37-001"
$AuthorizationId = "CAUTH-8A37-001"
$ExecutionId = "EXEC-8A37-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"

$source = Register-RevocationSource `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -ConsumptionId $ConsumptionId `
    -AuthorizationId $AuthorizationId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

$recordsBefore = @(Get-RevocationSyncRecords)

# ============================================================
# 17-19 SOURCE
# ============================================================

$t17 = $source.Allowed -eq $true
Add-Test "17 revocation source registered" $t17

$t18 = (
    $recordsBefore.Count -eq 1 -and
    $recordsBefore[0].SourceRevocationStatus -eq "REVOKED"
)
Add-Test "18 source marked revoked" $t18

$t19 = (
    $recordsBefore[0].PropagationStatus -eq "PENDING" -and
    $recordsBefore[0].SynchronizationStatus -eq "PENDING"
)
Add-Test "19 propagation begins pending" $t19

# ============================================================
# PROPAGATION
# ============================================================

$propagation = Invoke-RevocationPropagation `
    -SyncId $source.SyncId `
    -EnforcementRevoked $true `
    -ConsumptionRevoked $true `
    -AuthorizationRevoked $true `
    -ExecutionBlocked $true

$recordsAfter = @(Get-RevocationSyncRecords)

# ============================================================
# 20-24
# ============================================================

$t20 = (
    $propagation.Allowed -eq $true -and
    $propagation.Code -eq "REVOCATION_PROPAGATED_AND_SYNCHRONIZED"
)
Add-Test "20 revocation propagation completed" $t20

$t21 = (
    $recordsAfter[0].EnforcementSynced -eq $true -and
    $recordsAfter[0].ConsumptionSynced -eq $true -and
    $recordsAfter[0].AuthorizationSynced -eq $true -and
    $recordsAfter[0].ExecutionSynced -eq $true
)
Add-Test "21 all modules synchronized" $t21

$t22 = (
    $recordsAfter[0].PropagationStatus -eq "PROPAGATED" -and
    $recordsAfter[0].SynchronizationStatus -eq "SYNCHRONIZED" -and
    $recordsAfter[0].KillSwitchActive -eq $true
)
Add-Test "22 propagation final state coherent" $t22

$validation = Test-RevocationPropagation `
    -SyncId $source.SyncId

$t23 = (
    $validation.Allowed -eq $true -and
    $validation.Decision -eq "ALLOW" -and
    $validation.Code -eq "REVOCATION_PROPAGATION_VALID"
)
Add-Test "23 synchronized revocation accepted" $t23

$integrity = Test-RevocationSynchronizationIntegrity

$rawState = Get-Content `
    -LiteralPath "$Root\state\sync-records.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "REVOCATION_SYNC_INTEGRITY_VALID" -and
    $recordsAfter[0].ReactivationAllowed -eq $false -and
    $recordsAfter[0].ReopenAllowed -eq $false -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "24 cross-module sync integrity and no secrets persisted" $t24

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
Write-Host "RESULTAT 8A-37 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-37 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-37 : ECHEC - NE PAS PASSER A 8A-38" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
