$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Global-Recovery-Security-Seal.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-41 GLOBAL RECOVERY SECURITY SEAL GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-GlobalRecoverySeal

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

$config = Get-GlobalRecoverySealConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 global seal module enabled" $t01

$t02 = $config.sealEnabled -eq $true
Add-Test "02 security seal enabled" $t02

$t03 = $config.verificationEnabled -eq $true
Add-Test "03 seal verification enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireGlobalConsistency -eq $true
Add-Test "05 global consistency required" $t05

$t06 = $config.requireFinalization -eq $true
Add-Test "06 finalization required" $t06

$t07 = $config.requirePermanentLock -eq $true
Add-Test "07 permanent lock required" $t07

$t08 = $config.requireAuditIntegrity -eq $true
Add-Test "08 audit integrity required" $t08

$t09 = $config.requireFinalEnforcement -eq $true
Add-Test "09 final enforcement required" $t09

$t10 = $config.requireAntiReplay -eq $true
Add-Test "10 anti-replay required" $t10

$t11 = $config.requireTenantIsolation -eq $true
Add-Test "11 tenant isolation required" $t11

$t12 = $config.requirePermanentEvidence -eq $true
Add-Test "12 permanent evidence required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command New-GlobalRecoverySecuritySeal -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 security seal creator exists" $t13

$cmd14 = Get-Command Test-GlobalRecoverySecuritySeal -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 security seal validator exists" $t14

$cmd15 = Get-Command Test-GlobalRecoverySealIntegrity -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 security seal integrity validator exists" $t15

$cmd16 = Get-Command Test-GlobalRecoverySealScope -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 security seal scope validator exists" $t16

# ============================================================
# CONTROLLED COMPLETE CHAIN
# ============================================================

$GlobalCheckId = "GLOBAL-8A41-001"
$FinalizationId = "FINAL-8A41-001"
$FinalizationEventId = "AUDIT-8A41-001"

$EnforcementId = "ENF-8A41-001"
$ConsumptionId = "CONSUME-8A41-001"
$AuthorizationId = "CAUTH-8A41-001"
$ExecutionId = "EXEC-8A41-001"

$ConflictId = "CONFLICT-8A41-001"
$ClosureId = "CLOSURE-8A41-001"
$EvidenceId = "EVIDENCE-8A41-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$UserId = "USER-001"
$WorkerId = "SAM"

$seal = New-GlobalRecoverySecuritySeal `
    -GlobalCheckId $GlobalCheckId `
    -FinalizationId $FinalizationId `
    -FinalizationEventId $FinalizationEventId `
    -EnforcementId $EnforcementId `
    -ConsumptionId $ConsumptionId `
    -AuthorizationId $AuthorizationId `
    -ExecutionId $ExecutionId `
    -ConflictId $ConflictId `
    -ClosureId $ClosureId `
    -EvidenceId $EvidenceId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId `
    -GlobalConsistent $true `
    -Finalized $true `
    -PermanentLock $true `
    -AuditIntegrity $true `
    -FinalEnforcement $true `
    -AntiReplayValid $true `
    -TenantIsolationValid $true `
    -RevocationValid $true `
    -RevocationSyncValid $true `
    -ConflictResolved $true `
    -ConflictClosed $true `
    -EvidenceValid $true

$records = @(Get-GlobalRecoverySealRecords)

# ============================================================
# 17-24
# ============================================================

$t17 = $seal.Allowed -eq $true
Add-Test "17 global security seal created" $t17

$t18 = (
    $seal.Decision -eq "ALLOW" -and
    $seal.Code -eq "GLOBAL_SECURITY_SEAL_CREATED"
)
Add-Test "18 seal creation decision valid" $t18

$t19 = (
    $records.Count -eq 1 -and
    $records[0].SealStatus -eq "SEALED"
)
Add-Test "19 permanent seal persisted" $t19

$t20 = (
    $records[0].GlobalConsistent -eq $true -and
    $records[0].Finalized -eq $true -and
    $records[0].PermanentLock -eq $true -and
    $records[0].AuditIntegrity -eq $true
)
Add-Test "20 upstream security states captured" $t20

$t21 = (
    $records[0].FinalEnforcement -eq $true -and
    $records[0].AntiReplayValid -eq $true -and
    $records[0].TenantIsolationValid -eq $true -and
    $records[0].RevocationValid -eq $true
)
Add-Test "21 execution security controls captured" $t21

$t22 = (
    $records[0].RevocationSyncValid -eq $true -and
    $records[0].ConflictResolved -eq $true -and
    $records[0].ConflictClosed -eq $true -and
    $records[0].EvidenceValid -eq $true
)
Add-Test "22 recovery closure controls captured" $t22

$validation = Test-GlobalRecoverySecuritySeal `
    -SealId $seal.SealId

$scope = Test-GlobalRecoverySealScope `
    -SealId $seal.SealId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId

$t23 = (
    $validation.Allowed -eq $true -and
    $validation.Code -eq "GLOBAL_SECURITY_SEAL_VALID" -and
    $scope.Allowed -eq $true -and
    $scope.Code -eq "GLOBAL_SEAL_SCOPE_VALID"
)
Add-Test "23 seal validity and scope verified" $t23

$integrity = Test-GlobalRecoverySealIntegrity

$rawState = Get-Content `
    -LiteralPath "$Root\state\seals.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "GLOBAL_SECURITY_SEAL_INTEGRITY_VALID" -and
    $records[0].SecuritySealHash.Length -eq 64 -and
    $records[0].PermanentSeal -eq $true -and
    $records[0].Immutable -eq $true -and
    $records[0].MutationAllowed -eq $false -and
    $records[0].ReuseAllowed -eq $false -and
    $records[0].TamperDetected -eq $false -and
    $records[0].CrossTenantAllowed -eq $false -and
    $records[0].StaleSealAllowed -eq $false -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 global security seal integrity and protections valid" $t24

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
Write-Host "RESULTAT 8A-41 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-41 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-41 : ECHEC - NE PAS PASSER A 8A-42" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
