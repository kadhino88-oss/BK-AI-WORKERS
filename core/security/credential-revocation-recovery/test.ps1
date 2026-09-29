$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Revocation-Recovery.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-23 CREDENTIAL REVOCATION RECOVERY GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRevocationRecovery

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

$CredentialRef = "cred:test:recovery"

$OldChainId = "CHAIN-OLD-8A23"
$OldLeaseId = "LEASE-OLD-8A23"
$OldMaterializationId = "MAT-OLD-8A23"
$OldUsageId = "USE-OLD-8A23"
$OldExecutionId = "EXEC-OLD-8A23"

# ============================================================
# 01-12 CONFIG
# ============================================================

$config = Get-CredentialRevocationRecoveryConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.recoveryGuardEnabled -eq $true
Add-Test "02 recovery guard enabled" $t02

$t03 = $config.newChainRequired -eq $true
Add-Test "03 new chain required" $t03

$t04 = $config.oldChainImmutable -eq $true
Add-Test "04 old chain immutable" $t04

$t05 = $config.blockRevokedChainRecovery -eq $true
Add-Test "05 revoked chain recovery blocked" $t05

$t06 = $config.blockStaleBindingRecovery -eq $true
Add-Test "06 stale binding recovery blocked" $t06

$t07 = $config.failClosed -eq $true
Add-Test "07 fail closed enabled" $t07

$t08 = $config.requireCredentialBinding -eq $true
Add-Test "08 credential binding required" $t08

$t09 = $config.requireParentRevocationReference -eq $true
Add-Test "09 parent revocation reference required" $t09

$t10 = $config.requireNewChainId -eq $true
Add-Test "10 new chain id required" $t10

$t11 = $config.requireNewLeaseId -eq $true
Add-Test "11 new lease id required" $t11

$t12 = $config.requireNewExecutionId -eq $true
Add-Test "12 new execution id required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-CredentialRevokedChain -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 revoked chain registration exists" $t13

$cmd14 = Get-Command Recover-CredentialWithNewChain -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 new chain recovery exists" $t14

$cmd15 = Get-Command Test-CredentialRecoveryChain -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 recovery validator exists" $t15

$cmd16 = Get-Command Test-CredentialOldChainReuse -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 old chain reuse validator exists" $t16

# ============================================================
# REGISTER OLD REVOKED CHAIN
# ============================================================

$old = Register-CredentialRevokedChain `
    -CredentialRef $CredentialRef `
    -ChainId $OldChainId `
    -LeaseId $OldLeaseId `
    -MaterializationId $OldMaterializationId `
    -UsageId $OldUsageId `
    -ExecutionId $OldExecutionId

$oldRecord = Get-CredentialRevocationRecoveryRecord `
    -RecoveryId $old.RecoveryId

# ============================================================
# 17-24
# ============================================================

$t17 = $old.Allowed -eq $true
Add-Test "17 revoked parent chain registered" $t17

$t18 = (
    $oldRecord.ChainStatus -eq "REVOKED" -and
    $oldRecord.RecoveryStatus -eq "CLOSED"
)
Add-Test "18 parent chain closed and revoked" $t18

$t19 = $oldRecord.ReactivationAllowed -eq $false
Add-Test "19 parent reactivation disabled" $t19

$oldReuse = Test-CredentialOldChainReuse `
    -RecoveryId $old.RecoveryId

$t20 = (
    $oldReuse.Allowed -eq $false -and
    $oldReuse.Code -eq "OLD_CHAIN_REVOKED"
)
Add-Test "20 old chain reuse blocked" $t20

$newRecovery = Recover-CredentialWithNewChain `
    -ParentRecoveryId $old.RecoveryId `
    -CredentialRef $CredentialRef

$newRecord = Get-CredentialRevocationRecoveryRecord `
    -RecoveryId $newRecovery.RecoveryId

$t21 = $newRecovery.Allowed -eq $true
Add-Test "21 new recovery authorized" $t21

$t22 = (
    $newRecord.ChainId -ne $oldRecord.ChainId -and
    $newRecord.LeaseId -ne $oldRecord.LeaseId -and
    $newRecord.MaterializationId -ne $oldRecord.MaterializationId -and
    $newRecord.UsageId -ne $oldRecord.UsageId -and
    $newRecord.ExecutionId -ne $oldRecord.ExecutionId
)
Add-Test "22 recovery created completely new chain bindings" $t22

$t23 = (
    $newRecord.ParentRecoveryId -eq $oldRecord.RecoveryId -and
    $newRecord.ParentChainId -eq $oldRecord.ChainId -and
    $newRecord.ChainStatus -eq "ACTIVE" -and
    $newRecord.RecoveryStatus -eq "ACTIVE" -and
    $newRecord.ReactivationAllowed -eq $false
)
Add-Test "23 new chain correctly references revoked parent" $t23

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t24 = (
    ($rawState -notmatch '"RawSecret"\s*:\s*"[^"]+') -and
    ($rawState -notmatch '"RawCredential"\s*:\s*"[^"]+')
)
Add-Test "24 no raw credential material persisted" $t24

# ============================================================
# FINAL STRICT
# ============================================================

$total = $results.Count

$pass = @(
    $results | Where-Object {
        $_.Result -eq "PASS"
    }
).Count

$fail = @(
    $results | Where-Object {
        $_.Result -eq "FAIL"
    }
).Count

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : $total" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-23 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-23 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-23 : ECHEC - NE PAS PASSER A 8A-24" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
