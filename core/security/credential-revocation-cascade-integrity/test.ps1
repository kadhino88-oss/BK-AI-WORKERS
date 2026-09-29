$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Revocation-Cascade-Integrity.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-20 CREDENTIAL REVOCATION CASCADE INTEGRITY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRevocationCascadeIntegrity

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

$CredentialRef = "cred:test:banking"
$LeaseId = "LEASE-8A20-001"
$MaterializationId = "MAT-8A20-001"
$UsageId = "USE-8A20-001"
$ExecutionId = "EXEC-8A20-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "BANKING-API"
$ProjectId = "PROJECT-001"
$ClientId = "CLIENT-001"
$TenantId = "TENANT-001"

# ============================================================
# 01-12 CONFIGURATION
# ============================================================

$config = Get-CredentialRevocationCascadeIntegrityConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.cascadeIntegrityEnabled -eq $true
Add-Test "02 cascade integrity enabled" $t02

$t03 = $config.failClosed -eq $true
Add-Test "03 fail closed enabled" $t03

$t04 = $config.requireCredentialBinding -eq $true
Add-Test "04 credential binding required" $t04

$t05 = $config.requireLeaseBinding -eq $true
Add-Test "05 lease binding required" $t05

$t06 = $config.requireMaterializationBinding -eq $true
Add-Test "06 materialization binding required" $t06

$t07 = $config.requireUsageBinding -eq $true
Add-Test "07 usage binding required" $t07

$t08 = $config.requireExecutionBinding -eq $true
Add-Test "08 execution binding required" $t08

$t09 = $config.requireWorkerBinding -eq $true
Add-Test "09 worker binding required" $t09

$t10 = $config.requireActionBinding -eq $true
Add-Test "10 action binding required" $t10

$t11 = $config.requireConnectorBinding -eq $true
Add-Test "11 connector binding required" $t11

$t12 = $config.propagateRevocation -eq $true
Add-Test "12 revocation propagation enabled" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command New-ExecutionCredentialCascade -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 cascade constructor exists" $t13

$cmd14 = Get-Command Revoke-CredentialCascade -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 cascade revoke exists" $t14

$cmd15 = Get-Command Test-CredentialRevocationCascadeIntegrity -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 cascade integrity validator exists" $t15

$cmd16 = Get-Command Reset-CredentialRevocationCascadeIntegrity -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 reset exists" $t16

# ============================================================
# CREATE CASCADE
# ============================================================

$cascade = New-ExecutionCredentialCascade `
    -CredentialRef $CredentialRef `
    -LeaseId $LeaseId `
    -MaterializationId $MaterializationId `
    -UsageId $UsageId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$record = Get-CredentialRevocationCascadeIntegrityRecord `
    -CascadeId $cascade.CascadeId

# ============================================================
# 17-24 CASCADE INTEGRITY
# ============================================================

$t17 = $cascade.Allowed -eq $true
Add-Test "17 cascade authorized" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($cascade.CascadeId)
Add-Test "18 cascade id generated" $t18

$t19 = $record.CascadeHash.Length -eq 64
Add-Test "19 cascade integrity hash SHA256" $t19

$t20 = (
    $record.CredentialStatus -eq "ACTIVE" -and
    $record.LeaseStatus -eq "ACTIVE" -and
    $record.MaterializationStatus -eq "ACTIVE" -and
    $record.UsageStatus -eq "ACTIVE" -and
    $record.ExecutionStatus -eq "AUTHORIZED" -and
    $record.CascadeStatus -eq "ACTIVE" -and
    $record.Decision -eq "ALLOW"
)
Add-Test "20 complete cascade initially active" $t20

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t21 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "21 raw secret never persisted" $t21

$t22 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "22 raw credential never persisted" $t22

$before = Test-CredentialRevocationCascadeIntegrity `
    -CascadeId $cascade.CascadeId `
    -CredentialRef $CredentialRef `
    -LeaseId $LeaseId `
    -MaterializationId $MaterializationId `
    -UsageId $UsageId `
    -ExecutionId $ExecutionId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -ProjectId $ProjectId `
    -ClientId $ClientId `
    -TenantId $TenantId

$t23 = $before.Allowed -eq $true
Add-Test "23 intact cascade initially authorized" $t23

$revocation = Revoke-CredentialCascade `
    -CredentialRef $CredentialRef `
    -Reason "CREDENTIAL_REVOKED"

$revoked = Get-CredentialRevocationCascadeIntegrityRecord `
    -CascadeId $cascade.CascadeId

$after = Test-CredentialRevocationCascadeIntegrity `
    -CascadeId $cascade.CascadeId `
    -CredentialRef $CredentialRef `
    -LeaseId $LeaseId `
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
    $revocation.Status -eq "REVOKED" -and
    $revocation.AffectedCascadeCount -eq 1 -and
    $revoked.CredentialStatus -eq "REVOKED" -and
    $revoked.LeaseStatus -eq "REVOKED" -and
    $revoked.MaterializationStatus -eq "REVOKED" -and
    $revoked.UsageStatus -eq "REVOKED" -and
    $revoked.ExecutionStatus -eq "BLOCKED" -and
    $revoked.CascadeStatus -eq "REVOKED" -and
    $revoked.Decision -eq "BLOCK" -and
    $after.Allowed -eq $false -and
    $after.Code -eq "CASCADE_REVOKED"
)

Add-Test "24 revocation cascades and blocks execution" $t24

# ============================================================
# FINAL STRICT
# ============================================================

$total = $results.Count

$pass = @(
    $results | Where-Object { $_.Result -eq "PASS" }
).Count

$fail = @(
    $results | Where-Object { $_.Result -eq "FAIL" }
).Count

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : $total" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-20 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (($total -eq 24) -and ($pass -eq 24) -and ($fail -eq 0)) {

    Write-Host "8A-20 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-20 : ECHEC - NE PAS PASSER A 8A-21" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
