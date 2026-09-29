$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Final-Enforcement.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-33 CROSS-MODULE FINAL LOCK ENFORCEMENT GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryFinalEnforcement

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

$config = Get-CredentialRecoveryEnforcementConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 enforcement enabled" $t01

$t02 = $config.enforcementEnabled -eq $true
Add-Test "02 cross-module enforcement enabled" $t02

$t03 = $config.failClosed -eq $true
Add-Test "03 fail closed enabled" $t03

$t04 = $config.requireGlobalConsistency -eq $true
Add-Test "04 global consistency required" $t04

$t05 = $config.requireFinalization -eq $true
Add-Test "05 finalization required" $t05

$t06 = $config.requirePermanentLock -eq $true
Add-Test "06 permanent lock required" $t06

$t07 = $config.requireAuditIntegrity -eq $true
Add-Test "07 audit integrity required" $t07

$t08 = $config.requireTenantBinding -eq $true
Add-Test "08 tenant binding required" $t08

$t09 = $config.requireRecoveryBinding -eq $true
Add-Test "09 recovery binding required" $t09

$t10 = $config.requireFreshChain -eq $true
Add-Test "10 fresh chain required" $t10

$t11 = $config.blockPartialState -eq $true
Add-Test "11 partial state blocked" $t11

$t12 = $config.blockCrossTenantState -eq $true
Add-Test "12 cross-tenant state blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Invoke-CredentialRecoveryFinalEnforcement -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 enforcement function exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryFinalEnforcement -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 enforcement validator exists" $t14

$cmd15 = Get-Command Get-CredentialRecoveryEnforcementRecord -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 enforcement lookup exists" $t15

$cmd16 = Get-Command Get-CredentialRecoveryEnforcementHash -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 integrity hash function exists" $t16

# ============================================================
# CONTROLLED COMPLETE STATE
# ============================================================

$GlobalCheckId = "GLOBAL-8A33-001"
$FinalizationId = "FINAL-8A33-001"
$RecoveryId = "REC-8A33-001"
$AuditFinalizationEventId = "AUDIT-8A33-001"
$AuditIntegrityCode = "AUDIT_INTEGRITY_VALID"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$UserId = "USER-001"
$WorkerId = "SAM"

$OldChainId = "CHAIN-8A33-OLD"
$NewChainId = "CHAIN-8A33-NEW"
$NewLeaseId = "LEASE-8A33-NEW"
$NewMaterializationId = "MAT-8A33-NEW"
$NewUsageId = "USE-8A33-NEW"
$NewExecutionId = "EXEC-8A33-NEW"

$enforcement = Invoke-CredentialRecoveryFinalEnforcement `
    -GlobalCheckId $GlobalCheckId `
    -FinalizationId $FinalizationId `
    -RecoveryId $RecoveryId `
    -AuditFinalizationEventId $AuditFinalizationEventId `
    -AuditIntegrityCode $AuditIntegrityCode `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId `
    -OldChainId $OldChainId `
    -NewChainId $NewChainId `
    -NewLeaseId $NewLeaseId `
    -NewMaterializationId $NewMaterializationId `
    -NewUsageId $NewUsageId `
    -NewExecutionId $NewExecutionId `
    -GlobalConsistent $true `
    -Finalized $true `
    -PermanentLock $true `
    -Immutable $true `
    -OldChainRevoked $true `
    -NewChainActive $true `
    -FreshBindings $true

$record = Get-CredentialRecoveryEnforcementRecord `
    -EnforcementId $enforcement.EnforcementId

# ============================================================
# 17-24
# ============================================================

$t17 = $enforcement.Allowed -eq $true
Add-Test "17 complete recovery enforcement allowed" $t17

$t18 = $enforcement.Decision -eq "ALLOW"
Add-Test "18 enforcement decision allow" $t18

$t19 = $enforcement.EnforcementStatus -eq "ENFORCED"
Add-Test "19 enforcement status enforced" $t19

$t20 = $record.PermanentLock -eq $true
Add-Test "20 permanent lock preserved" $t20

$t21 = (
    $record.OldChainRevoked -eq $true -and
    $record.NewChainActive -eq $true -and
    $record.FreshBindings -eq $true
)
Add-Test "21 recovery chain state coherent" $t21

$t22 = (
    $record.ReopenAllowed -eq $false -and
    $record.ReactivationAllowed -eq $false -and
    $record.MutationAllowed -eq $false
)
Add-Test "22 reopen reactivation mutation blocked" $t22

$t23 = (
    $record.CrossTenantAllowed -eq $false -and
    $record.StaleStateAllowed -eq $false -and
    $record.TamperDetected -eq $false
)
Add-Test "23 isolation stale-state and tamper protections active" $t23

$rawState = Get-Content `
    -LiteralPath "$Root\state\enforcement.json" `
    -Raw

$t24 = (
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "24 no raw secrets or credentials persisted" $t24

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
Write-Host "RESULTAT 8A-33 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-33 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-33 : ECHEC - NE PAS PASSER A 8A-34" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
