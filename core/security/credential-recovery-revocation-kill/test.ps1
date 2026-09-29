$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Final-Revocation-Kill.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-36 FINAL ENFORCEMENT REVOCATION & KILL-SWITCH" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-FinalRevocation

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

$config = Get-FinalRevocationConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 revocation module enabled" $t01

$t02 = $config.revocationEnabled -eq $true
Add-Test "02 revocation enabled" $t02

$t03 = $config.killSwitchEnabled -eq $true
Add-Test "03 kill switch enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireEnforcementBinding -eq $true
Add-Test "05 enforcement binding required" $t05

$t06 = $config.requireConsumptionBinding -eq $true
Add-Test "06 consumption binding required" $t06

$t07 = $config.requireAuthorizationBinding -eq $true
Add-Test "07 authorization binding required" $t07

$t08 = $config.requireTenantBinding -eq $true
Add-Test "08 tenant binding required" $t08

$t09 = $config.requireExecutionBinding -eq $true
Add-Test "09 execution binding required" $t09

$t10 = $config.requireRevocationReason -eq $true
Add-Test "10 revocation reason required" $t10

$t11 = $config.blockRevokedExecution -eq $true
Add-Test "11 revoked execution blocked" $t11

$t12 = $config.cascadeRevocation -eq $true
Add-Test "12 cascade revocation enabled" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-FinalEnforcement -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 enforcement registration exists" $t13

$cmd14 = Get-Command Revoke-FinalEnforcement -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 revocation function exists" $t14

$cmd15 = Get-Command Test-FinalEnforcementRevocation -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 revocation validator exists" $t15

$cmd16 = Get-Command Test-RevocationCascadeIntegrity -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 cascade integrity validator exists" $t16

# ============================================================
# REGISTER ACTIVE ENFORCEMENT
# ============================================================

$EnforcementId = "ENF-8A36-001"
$RecoveryId = "REC-8A36-001"
$ConsumptionId = "CONSUME-8A36-001"
$AuthorizationId = "CAUTH-8A36-001"
$ExecutionId = "EXEC-8A36-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$UserId = "USER-001"
$WorkerId = "SAM"

$registration = Register-FinalEnforcement `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -ConsumptionId $ConsumptionId `
    -AuthorizationId $AuthorizationId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId

$before = Test-FinalEnforcementRevocation `
    -EnforcementId $EnforcementId

# ============================================================
# 17-19 ACTIVE STATE
# ============================================================

$t17 = $registration.Allowed -eq $true
Add-Test "17 active enforcement registered" $t17

$t18 = (
    $before.Allowed -eq $true -and
    $before.Decision -eq "ALLOW" -and
    $before.Code -eq "FINAL_ENFORCEMENT_ACTIVE"
)
Add-Test "18 active enforcement accepted" $t18

$recordsBefore = @(Get-FinalRevocationRecords)

$t19 = (
    $recordsBefore.Count -eq 1 -and
    $recordsBefore[0].RevocationStatus -eq "NOT_REVOKED" -and
    $null -eq $recordsBefore[0].RevocationActor -and
    $null -eq $recordsBefore[0].RevocationEventId
)
Add-Test "19 initial non-revoked state persisted" $t19

# ============================================================
# REVOCATION
# ============================================================

$revocation = Revoke-FinalEnforcement `
    -EnforcementId $EnforcementId `
    -Reason "SECURITY_POLICY_TEST" `
    -Actor "SYSTEM"

$recordsAfter = @(Get-FinalRevocationRecords)

# ============================================================
# 20-24
# ============================================================

$t20 = (
    $revocation.Allowed -eq $true -and
    $revocation.Code -eq "REVOCATION_CASCADE_APPLIED"
)
Add-Test "20 revocation cascade applied" $t20

$t21 = (
    $recordsAfter.Count -eq 1 -and
    $recordsAfter[0].EnforcementStatus -eq "REVOKED" -and
    $recordsAfter[0].ConsumptionStatus -eq "REVOKED" -and
    $recordsAfter[0].AuthorizationStatus -eq "REVOKED"
)
Add-Test "21 enforcement consumption authorization revoked" $t21

$t22 = (
    $recordsAfter[0].ExecutionStatus -eq "BLOCKED" -and
    $recordsAfter[0].KillSwitchActive -eq $true -and
    $recordsAfter[0].Decision -eq "BLOCK"
)
Add-Test "22 execution kill switch active" $t22

$revoked = Test-FinalEnforcementRevocation `
    -EnforcementId $EnforcementId

$t23 = (
    $revoked.Allowed -eq $false -and
    $revoked.Decision -eq "BLOCK" -and
    $revoked.Code -eq "FINAL_ENFORCEMENT_REVOKED" -and
    $revoked.KillSwitchActive -eq $true
)
Add-Test "23 revoked enforcement blocked immediately" $t23

$execution = Test-RevokedExecution `
    -EnforcementId $EnforcementId `
    -ExecutionId $ExecutionId

$cascade = Test-RevocationCascadeIntegrity

$eventIntegrity = Test-RevocationEventIntegrity `
    -EnforcementId $EnforcementId

$rawState = Get-Content `
    -LiteralPath "$Root\state\records.json" `
    -Raw

$t24 = (
    $execution.Allowed -eq $false -and
    $execution.Decision -eq "BLOCK" -and
    $execution.Code -eq "EXECUTION_KILLED" -and
    $cascade.Allowed -eq $true -and
    $cascade.Code -eq "REVOCATION_CASCADE_INTEGRITY_VALID" -and
    $eventIntegrity.Allowed -eq $true -and
    $eventIntegrity.Code -eq "REVOCATION_EVENT_INTEGRITY_VALID" -and
    $recordsAfter[0].ReactivationAllowed -eq $false -and
    $recordsAfter[0].ReopenAllowed -eq $false -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 kill switch integrity and no secrets persisted" $t24

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
Write-Host "RESULTAT 8A-36 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-36 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-36 : ECHEC - NE PAS PASSER A 8A-37" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
