$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Global-Seal-Lifecycle.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-42 GLOBAL SECURITY SEAL REVOCATION & LIFECYCLE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-GlobalSealLifecycle

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

$config = Get-GlobalSealLifecycleConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 lifecycle module enabled" $t01

$t02 = $config.lifecycleEnabled -eq $true
Add-Test "02 lifecycle enabled" $t02

$t03 = $config.revocationEnabled -eq $true
Add-Test "03 revocation enabled" $t03

$t04 = $config.closureEnabled -eq $true
Add-Test "04 closure enabled" $t04

$t05 = $config.failClosed -eq $true
Add-Test "05 fail closed enabled" $t05

$t06 = $config.requireSealIdentity -eq $true
Add-Test "06 seal identity required" $t06

$t07 = $config.requireTenantBinding -eq $true
Add-Test "07 tenant binding required" $t07

$t08 = $config.requireExecutionBinding -eq $true
Add-Test "08 execution binding required" $t08

$t09 = $config.requireSealIntegrity -eq $true
Add-Test "09 seal integrity required" $t09

$t10 = $config.blockRevokedState -eq $true
Add-Test "10 revoked state blocked" $t10

$t11 = $config.blockClosedState -eq $true
Add-Test "11 closed state blocked" $t11

$t12 = $config.blockReactivation -eq $true
Add-Test "12 reactivation blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-GlobalSecuritySealLifecycle -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 lifecycle registration exists" $t13

$cmd14 = Get-Command Activate-GlobalSecuritySeal -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 activation function exists" $t14

$cmd15 = Get-Command Revoke-GlobalSecuritySeal -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 revocation function exists" $t15

$cmd16 = Get-Command Close-GlobalSecuritySeal -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 closure function exists" $t16

# ============================================================
# CONTROLLED LIFECYCLE
# ============================================================

$SealId = "SEAL-8A42-001"
$SecuritySealHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$ExecutionId = "EXEC-8A42-001"

$registration = Register-GlobalSecuritySealLifecycle `
    -SealId $SealId `
    -SecuritySealHash $SecuritySealHash `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -SealValid $true `
    -Immutable $true `
    -PermanentSeal $true

$records1 = @(Get-GlobalSealLifecycleRecords)

# ============================================================
# 17-18 SEALED
# ============================================================

$t17 = (
    $registration.Allowed -eq $true -and
    $registration.LifecycleState -eq "SEALED"
)
Add-Test "17 security seal lifecycle registered" $t17

$t18 = (
    $records1.Count -eq 1 -and
    $records1[0].LifecycleState -eq "SEALED"
)
Add-Test "18 sealed state persisted" $t18

# ============================================================
# ACTIVATE
# ============================================================

$activation = Activate-GlobalSecuritySeal `
    -LifecycleId $registration.LifecycleId

$records2 = @(Get-GlobalSealLifecycleRecords)

# ============================================================
# 19-20 ACTIVE
# ============================================================

$t19 = (
    $activation.Allowed -eq $true -and
    $activation.Code -eq "SEAL_ACTIVATED"
)
Add-Test "19 security seal activated" $t19

$t20 = (
    $records2[0].LifecycleState -eq "ACTIVE" -and
    $records2[0].Decision -eq "ALLOW"
)
Add-Test "20 active state valid" $t20

# ============================================================
# REVOKE
# ============================================================

$revocation = Revoke-GlobalSecuritySeal `
    -LifecycleId $registration.LifecycleId `
    -Reason "SECURITY_POLICY_TEST" `
    -Actor "SYSTEM"

$records3 = @(Get-GlobalSealLifecycleRecords)

# ============================================================
# 21-24
# ============================================================

$t21 = (
    $revocation.Allowed -eq $true -and
    $revocation.Decision -eq "BLOCK" -and
    $revocation.LifecycleState -eq "REVOKED"
)
Add-Test "21 security seal revoked and blocked" $t21

$t22 = (
    $records3[0].Revoked -eq $true -and
    $records3[0].RevokedAtUtc -ne $null -and
    $records3[0].RevocationReason -eq "SECURITY_POLICY_TEST" -and
    $records3[0].RevocationActor -eq "SYSTEM"
)
Add-Test "22 revocation evidence persisted" $t22

$close = Close-GlobalSecuritySeal `
    -LifecycleId $registration.LifecycleId

$records4 = @(Get-GlobalSealLifecycleRecords)

$t23 = (
    $close.Allowed -eq $true -and
    $close.Decision -eq "BLOCK" -and
    $close.LifecycleState -eq "CLOSED" -and
    $records4[0].Closed -eq $true -and
    $records4[0].ReactivationAllowed -eq $false -and
    $records4[0].ReopenAllowed -eq $false -and
    $records4[0].ReuseAllowed -eq $false
)
Add-Test "23 permanent closure blocks reactivation reopen reuse" $t23

$validation = Test-GlobalSecuritySealLifecycle `
    -LifecycleId $registration.LifecycleId

$integrity = Test-GlobalSealLifecycleIntegrity

$scope = Test-GlobalSealLifecycleScope `
    -LifecycleId $registration.LifecycleId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId

$rawState = Get-Content `
    -LiteralPath "$Root\state\lifecycle.json" `
    -Raw

$t24 = (
    $validation.Allowed -eq $false -and
    $validation.Decision -eq "BLOCK" -and
    $validation.Code -eq "SEAL_TERMINAL_STATE" -and
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "SEAL_LIFECYCLE_INTEGRITY_VALID" -and
    $scope.Allowed -eq $true -and
    $scope.Code -eq "SEAL_LIFECYCLE_SCOPE_VALID" -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 terminal lifecycle integrity scope and secrets protection valid" $t24

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
Write-Host "RESULTAT 8A-42 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-42 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-42 : ECHEC - NE PAS PASSER A 8A-43" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
