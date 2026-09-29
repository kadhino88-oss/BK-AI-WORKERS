$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Final-Lock.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-31 CREDENTIAL RECOVERY FINALIZATION & PERMANENT LOCK" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryFinalLock

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

$GlobalCheckId = "GLOBAL-8A31-001"
$RecoveryId = "REC-8A31-001"
$AuthorizationId = "RAUTH-8A31-001"
$ContextId = "CTX-8A31-001"
$ActivationId = "ACT-8A31-001"
$IntegrityId = "INT-8A31-001"
$OldChainId = "CHAIN-8A31-OLD"
$NewChainId = "CHAIN-8A31-NEW"
$NewLeaseId = "LEASE-8A31-NEW"
$NewMaterializationId = "MAT-8A31-NEW"
$NewUsageId = "USE-8A31-NEW"
$NewExecutionId = "EXEC-8A31-NEW"
$UserId = "USER-001"
$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "CONTROLLED-API"

# ============================================================
# 01-12 CONFIG
# ============================================================

$config = Get-CredentialRecoveryFinalLockConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.finalizationGuardEnabled -eq $true
Add-Test "02 finalization guard enabled" $t02

$t03 = $config.permanentLockEnabled -eq $true
Add-Test "03 permanent lock enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireGlobalConsistency -eq $true
Add-Test "05 global consistency required" $t05

$t06 = $config.requireCompleteRecovery -eq $true
Add-Test "06 complete recovery required" $t06

$t07 = $config.requireOldChainRevoked -eq $true
Add-Test "07 old chain revocation required" $t07

$t08 = $config.requireNewChainActive -eq $true
Add-Test "08 new chain active required" $t08

$t09 = $config.requireFreshBindings -eq $true
Add-Test "09 fresh bindings required" $t09

$t10 = $config.blockReopen -eq $true
Add-Test "10 reopen blocked" $t10

$t11 = $config.blockReactivation -eq $true
Add-Test "11 reactivation blocked" $t11

$t12 = $config.blockMutation -eq $true
Add-Test "12 mutation blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Finalize-CredentialRecovery -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 finalization function exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryFinalization -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 finalization validator exists" $t14

$cmd15 = Get-Command Test-CredentialRecoveryReopen -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 reopen validator exists" $t15

$cmd16 = Get-Command Get-CredentialRecoveryFinalLockRecord -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 finalization lookup exists" $t16

# ============================================================
# FINALIZE RECOVERY
# ============================================================

$final = Finalize-CredentialRecovery `
    -GlobalCheckId $GlobalCheckId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -ContextId $ContextId `
    -ActivationId $ActivationId `
    -IntegrityId $IntegrityId `
    -OldChainId $OldChainId `
    -NewChainId $NewChainId `
    -NewLeaseId $NewLeaseId `
    -NewMaterializationId $NewMaterializationId `
    -NewUsageId $NewUsageId `
    -NewExecutionId $NewExecutionId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector

$record = Get-CredentialRecoveryFinalLockRecord `
    -FinalizationId $final.FinalizationId

# ============================================================
# 17-24
# ============================================================

$t17 = $final.Allowed -eq $true
Add-Test "17 recovery finalized" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($final.FinalizationId)
Add-Test "18 finalization id generated" $t18

$t19 = $final.FinalizationHash.Length -eq 64
Add-Test "19 finalization hash SHA256" $t19

$t20 = (
    $record.FinalizationStatus -eq "FINALIZED" -and
    $record.Decision -eq "ALLOW" -and
    $record.Immutable -eq $true -and
    $record.PermanentLock -eq $true
)
Add-Test "20 permanent final state persisted" $t20

$t21 = (
    $record.OldChainStatus -eq "REVOKED" -and
    $record.NewChainStatus -eq "ACTIVE" -and
    $record.NewLeaseStatus -eq "ACTIVE" -and
    $record.NewMaterializationStatus -eq "ACTIVE" -and
    $record.NewUsageStatus -eq "ACTIVE" -and
    $record.NewExecutionStatus -eq "AUTHORIZED"
)
Add-Test "21 final chain state coherent" $t21

$rawState = Get-Content `
    -LiteralPath "$Root\state\records.json" `
    -Raw

$t22 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "22 raw secret never persisted" $t22

$t23 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "23 raw credential never persisted" $t23

$finalValidation = Test-CredentialRecoveryFinalization `
    -FinalizationId $final.FinalizationId

$reopen = Test-CredentialRecoveryReopen `
    -FinalizationId $final.FinalizationId

$t24 = (
    $finalValidation.Allowed -eq $true -and
    $finalValidation.Code -eq "FINALIZED_AND_LOCKED" -and
    $reopen.Allowed -eq $false -and
    $reopen.Code -eq "PERMANENT_LOCK"
)
Add-Test "24 final state locked against reopen" $t24

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
Write-Host "RESULTAT 8A-31 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-31 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-31 : ECHEC - NE PAS PASSER A 8A-32" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
