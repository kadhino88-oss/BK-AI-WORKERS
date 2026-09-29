$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Global.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-30 CREDENTIAL RECOVERY GLOBAL CONSISTENCY GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryGlobal

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

$RecoveryId = "REC-8A30-001"
$AuthorizationId = "RAUTH-8A30-001"
$ContextId = "CTX-8A30-001"
$ActivationId = "ACT-8A30-001"
$IntegrityId = "INT-8A30-001"
$OldChainId = "CHAIN-8A30-OLD"
$NewChainId = "CHAIN-8A30-NEW"
$NewLeaseId = "LEASE-8A30-NEW"
$NewMaterializationId = "MAT-8A30-NEW"
$NewUsageId = "USE-8A30-NEW"
$NewExecutionId = "EXEC-8A30-NEW"
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

$config = Get-CredentialRecoveryGlobalConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.globalConsistencyEnabled -eq $true
Add-Test "02 global consistency enabled" $t02

$t03 = $config.failClosed -eq $true
Add-Test "03 fail closed enabled" $t03

$t04 = $config.requireRecoveryGuard -eq $true
Add-Test "04 recovery guard required" $t04

$t05 = $config.requireAuthorizationGuard -eq $true
Add-Test "05 authorization guard required" $t05

$t06 = $config.requireContextGuard -eq $true
Add-Test "06 context guard required" $t06

$t07 = $config.requireActivationGuard -eq $true
Add-Test "07 activation guard required" $t07

$t08 = $config.requireActivationIntegrity -eq $true
Add-Test "08 activation integrity required" $t08

$t09 = $config.requireActivationAudit -eq $true
Add-Test "09 activation audit required" $t09

$t10 = $config.requireCompletionGuard -eq $true
Add-Test "10 completion guard required" $t10

$t11 = $config.requireOldChainRevoked -eq $true
Add-Test "11 old chain revocation required" $t11

$t12 = $config.requireNewChainActive -eq $true
Add-Test "12 new chain active required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Invoke-CredentialRecoveryGlobalCheck -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 global check function exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryGlobalConsistency -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 global validator exists" $t14

$cmd15 = Get-Command Get-CredentialRecoveryGlobalRecord -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 global record lookup exists" $t15

$cmd16 = Get-Command Reset-CredentialRecoveryGlobal -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 reset exists" $t16

# ============================================================
# GLOBAL CHECK
# ============================================================

$check = Invoke-CredentialRecoveryGlobalCheck `
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

$record = Get-CredentialRecoveryGlobalRecord `
    -GlobalCheckId $check.GlobalCheckId

# ============================================================
# 17-24
# ============================================================

$t17 = $check.Allowed -eq $true
Add-Test "17 global consistency check authorized" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($check.GlobalCheckId)
Add-Test "18 global check id generated" $t18

$t19 = $check.GlobalCheckHash.Length -eq 64
Add-Test "19 global check hash SHA256" $t19

$t20 = (
    $record.GlobalStatus -eq "CONSISTENT" -and
    $record.RecoveryStatus -eq "COMPLETED" -and
    $record.Decision -eq "ALLOW"
)
Add-Test "20 completed global state persisted" $t20

$t21 = (
    $record.OldChainStatus -eq "REVOKED" -and
    $record.OldLeaseStatus -eq "REVOKED" -and
    $record.OldMaterializationStatus -eq "REVOKED" -and
    $record.OldUsageStatus -eq "REVOKED"
)
Add-Test "21 all old bindings remain revoked" $t21

$t22 = (
    $record.NewChainStatus -eq "ACTIVE" -and
    $record.NewLeaseStatus -eq "ACTIVE" -and
    $record.NewMaterializationStatus -eq "ACTIVE" -and
    $record.NewUsageStatus -eq "ACTIVE" -and
    $record.NewExecutionStatus -eq "AUTHORIZED"
)
Add-Test "22 all new bindings remain coherent" $t22

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t23 = (
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "23 no raw credential material persisted" $t23

$validation = Test-CredentialRecoveryGlobalConsistency `
    -GlobalCheckId $check.GlobalCheckId

$t24 = (
    $validation.Allowed -eq $true -and
    $validation.Code -eq "GLOBAL_CONSISTENT"
)
Add-Test "24 global recovery state consistent" $t24

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
Write-Host "RESULTAT 8A-30 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-30 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-30 : ECHEC - NE PAS PASSER A 8A-31" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
