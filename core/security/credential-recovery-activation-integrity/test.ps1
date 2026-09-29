$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Activation-Integrity.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-27 CREDENTIAL RECOVERY ACTIVATION INTEGRITY & ANTI-TAMPER" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryActivationIntegrity

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

$AuthorizationId = "RAUTH-8A27-001"
$ContextId = "CTX-8A27-001"
$OldChainId = "CHAIN-8A27-OLD"
$NewChainId = "CHAIN-8A27-NEW"
$NewLeaseId = "LEASE-8A27-NEW"
$NewMaterializationId = "MAT-8A27-NEW"
$NewUsageId = "USE-8A27-NEW"
$NewExecutionId = "EXEC-8A27-NEW"
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

$config = Get-CredentialRecoveryActivationIntegrityConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.integrityGuardEnabled -eq $true
Add-Test "02 integrity guard enabled" $t02

$t03 = $config.antiTamperEnabled -eq $true
Add-Test "03 anti-tamper enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireAuthorizationBinding -eq $true
Add-Test "05 authorization binding required" $t05

$t06 = $config.requireContextBinding -eq $true
Add-Test "06 context binding required" $t06

$t07 = $config.requireOldChainBinding -eq $true
Add-Test "07 old chain binding required" $t07

$t08 = $config.requireNewChainBinding -eq $true
Add-Test "08 new chain binding required" $t08

$t09 = $config.requireLeaseBinding -eq $true
Add-Test "09 lease binding required" $t09

$t10 = $config.requireMaterializationBinding -eq $true
Add-Test "10 materialization binding required" $t10

$t11 = $config.requireUsageBinding -eq $true
Add-Test "11 usage binding required" $t11

$t12 = $config.requireExecutionBinding -eq $true
Add-Test "12 execution binding required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-CredentialRecoveryActivationIntegrity -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 integrity registration exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryActivationIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 integrity validator exists" $t14

$cmd15 = Get-Command Mark-CredentialRecoveryActivationTampered -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 tamper marker exists" $t15

$cmd16 = Get-Command Reset-CredentialRecoveryActivationIntegrity -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 reset exists" $t16

# ============================================================
# REGISTER INTEGRITY
# ============================================================

$integrity = Register-CredentialRecoveryActivationIntegrity `
    -AuthorizationId $AuthorizationId `
    -ContextId $ContextId `
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

$record = Get-CredentialRecoveryActivationIntegrityRecord `
    -IntegrityId $integrity.IntegrityId

# ============================================================
# 17-24
# ============================================================

$t17 = $integrity.Allowed -eq $true
Add-Test "17 integrity record authorized" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($integrity.IntegrityId)
Add-Test "18 integrity id generated" $t18

$t19 = $integrity.IntegrityHash.Length -eq 64
Add-Test "19 integrity hash SHA256" $t19

$t20 = (
    $record.Status -eq "VALID" -and
    $record.Decision -eq "ALLOW" -and
    $record.Immutable -eq $true
)
Add-Test "20 valid immutable activation state" $t20

$rawState = Get-Content `
    -LiteralPath "$Root\state\records.json" `
    -Raw

$t21 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "21 raw secret never persisted" $t21

$t22 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "22 raw credential never persisted" $t22

$valid = Test-CredentialRecoveryActivationIntegrity `
    -IntegrityId $integrity.IntegrityId `
    -AuthorizationId $AuthorizationId `
    -ContextId $ContextId `
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

$t23 = (
    $valid.Allowed -eq $true -and
    $valid.Code -eq "INTEGRITY_VALID"
)
Add-Test "23 valid activation integrity authorized" $t23

$tamper = Mark-CredentialRecoveryActivationTampered `
    -IntegrityId $integrity.IntegrityId

$tamperedRecord = Get-CredentialRecoveryActivationIntegrityRecord `
    -IntegrityId $integrity.IntegrityId

$t24 = (
    $tamper.Status -eq "TAMPERED" -and
    $tamperedRecord.Status -eq "TAMPERED" -and
    $tamperedRecord.Decision -eq "BLOCK" -and
    -not [string]::IsNullOrWhiteSpace(
        $tamperedRecord.TamperDetectedAtUtc
    )
)
Add-Test "24 tampered activation blocked" $t24

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
Write-Host "RESULTAT 8A-27 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-27 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-27 : ECHEC - NE PAS PASSER A 8A-28" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
