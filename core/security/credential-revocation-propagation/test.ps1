$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Revocation-Propagation.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-19 CREDENTIAL REVOCATION PROPAGATION & KILL SWITCH" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRevocationPropagation

$results = @()

function Add-Test {
    param(
        [string]$Name,
        [bool]$Passed
    )

    $status = "FAIL"

    if ($Passed) {
        $status = "PASS"
        Write-Host "[PASS] $Name" -ForegroundColor Green
    }
    else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
    }

    $script:results += [pscustomobject]@{
        Test = $Name
        Result = $status
    }
}

$CredentialRef = "cred:test:banking"
$MaterializationId = "MAT-8A19-001"
$UsageId = "USE-8A19-001"
$ExecutionId = "EXEC-8A19-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "BANKING-API"
$ProjectId = "PROJECT-001"
$ClientId = "CLIENT-001"
$TenantId = "TENANT-001"

# ============================================================
# 01-10 CONFIG
# ============================================================

$config = Get-CredentialRevocationPropagationConfig

$t01 = ($config.enabled -eq $true)
Add-Test "01 config enabled" $t01

$t02 = ($config.revocationPropagationEnabled -eq $true)
Add-Test "02 revocation propagation enabled" $t02

$t03 = ($config.activeUsageKillSwitchEnabled -eq $true)
Add-Test "03 active usage kill switch enabled" $t03

$t04 = ($config.failClosed -eq $true)
Add-Test "04 fail closed enabled" $t04

$t05 = ($config.requireCredentialBinding -eq $true)
Add-Test "05 credential binding required" $t05

$t06 = ($config.requireMaterializationBinding -eq $true)
Add-Test "06 materialization binding required" $t06

$t07 = ($config.requireUsageBinding -eq $true)
Add-Test "07 usage binding required" $t07

$t08 = ($config.requireExecutionBinding -eq $true)
Add-Test "08 execution binding required" $t08

$t09 = ($config.requireWorkerBinding -eq $true)
Add-Test "09 worker binding required" $t09

$t10 = ($config.propagateRevocationImmediately -eq $true)
Add-Test "10 immediate propagation enabled" $t10

# ============================================================
# 11-15 FUNCTIONS
# ============================================================

$t11 = $null -ne (Get-Command Register-CredentialActiveUsage -ErrorAction SilentlyContinue)
Add-Test "11 register function exists" $t11

$t12 = $null -ne (Get-Command Revoke-CredentialAndPropagate -ErrorAction SilentlyContinue)
Add-Test "12 revoke propagation function exists" $t12

$t13 = $null -ne (Get-Command Test-CredentialActiveUsage -ErrorAction SilentlyContinue)
Add-Test "13 active usage validator exists" $t13

$t14 = $null -ne (Get-Command Reset-CredentialRevocationPropagation -ErrorAction SilentlyContinue)
Add-Test "14 reset function exists" $t14

$initialCount = @(Get-CredentialRevocationPropagationRecords).Count
$t15 = ($initialCount -eq 0)
Add-Test "15 initial state empty" $t15

# ============================================================
# REGISTER ACTIVE USAGE
# ============================================================

$registration = Register-CredentialActiveUsage `
    -CredentialRef $CredentialRef `
    -MaterializationId $MaterializationId `
    -UsageId $UsageId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$record = Get-CredentialRevocationPropagationRecord `
    -RecordId $registration.RecordId

# ============================================================
# 16-24 SECURITY
# ============================================================

$t16 = ($registration.Allowed -eq $true)
Add-Test "16 active usage registered" $t16

$t17 = (-not [string]::IsNullOrWhiteSpace($registration.RecordId))
Add-Test "17 record id generated" $t17

$t18 = (
    $record.Status -eq "ACTIVE" -and
    $record.Decision -eq "ALLOW"
)
Add-Test "18 active state persisted" $t18

$t19 = ($record.CredentialRefHash.Length -eq 64)
Add-Test "19 credential reference hashed" $t19

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t20 = ($rawState -notmatch '"RawSecret"\s*:\s*"[^"]+')
Add-Test "20 raw secret never persisted" $t20

$t21 = ($rawState -notmatch '"RawCredential"\s*:\s*"[^"]+')
Add-Test "21 raw credential never persisted" $t21

$authorized = Test-CredentialActiveUsage `
    -RecordId $registration.RecordId `
    -CredentialRef $CredentialRef `
    -MaterializationId $MaterializationId `
    -UsageId $UsageId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$t22 = ($authorized.Allowed -eq $true)
Add-Test "22 active usage initially authorized" $t22

$revocation = Revoke-CredentialAndPropagate `
    -CredentialRef $CredentialRef `
    -Reason "SECURITY_REVOKED"

$revokedRecord = Get-CredentialRevocationPropagationRecord `
    -RecordId $registration.RecordId

$t23 = (
    $revocation.Status -eq "REVOKED" -and
    $revocation.AffectedUsageCount -eq 1 -and
    $revokedRecord.Status -eq "REVOKED" -and
    $revokedRecord.Decision -eq "BLOCK" -and
    -not [string]::IsNullOrWhiteSpace($revokedRecord.RevokedAtUtc)
)
Add-Test "23 revocation propagated to active usage" $t23

$blocked = Test-CredentialActiveUsage `
    -RecordId $registration.RecordId `
    -CredentialRef $CredentialRef `
    -MaterializationId $MaterializationId `
    -UsageId $UsageId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$t24 = (
    $blocked.Allowed -eq $false -and
    $blocked.Code -eq "REVOKED"
)
Add-Test "24 revoked usage immediately blocked" $t24

# ============================================================
# FINAL
# ============================================================

$pass = @(
    $results | Where-Object { $_.Result -eq "PASS" }
).Count

$fail = @(
    $results | Where-Object { $_.Result -eq "FAIL" }
).Count

$total = $results.Count

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : $total" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-19 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (($total -eq 24) -and ($pass -eq 24) -and ($fail -eq 0)) {
    Write-Host "8A-19 : VALIDEE - 24/0" -ForegroundColor Green
}
else {
    Write-Host "8A-19 : ECHEC - NE PAS PASSER A 8A-20" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
