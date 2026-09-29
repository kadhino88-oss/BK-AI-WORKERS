$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Seal-Retention-Guard.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-44 GLOBAL SECURITY SEAL EVIDENCE RETENTION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-SealRetention

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

$config = Get-SealRetentionConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 retention module enabled" $t01

$t02 = $config.retentionEnabled -eq $true
Add-Test "02 retention enabled" $t02

$t03 = $config.integrityEnabled -eq $true
Add-Test "03 retention integrity enabled" $t03

$t04 = $config.availabilityEnabled -eq $true
Add-Test "04 evidence availability enabled" $t04

$t05 = $config.failClosed -eq $true
Add-Test "05 fail closed enabled" $t05

$t06 = $config.requireEvidenceIdentity -eq $true
Add-Test "06 evidence identity required" $t06

$t07 = $config.requireSealIdentity -eq $true
Add-Test "07 seal identity required" $t07

$t08 = $config.requireTenantBinding -eq $true
Add-Test "08 tenant binding required" $t08

$t09 = $config.requireExecutionBinding -eq $true
Add-Test "09 execution binding required" $t09

$t10 = $config.requirePermanentEvidence -eq $true
Add-Test "10 permanent evidence required" $t10

$t11 = $config.requireImmutableEvidence -eq $true
Add-Test "11 immutable evidence required" $t11

$t12 = $config.requireHashIntegrity -eq $true
Add-Test "12 evidence hash integrity required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Register-SealEvidenceRetention -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 retention registration exists" $t13

$cmd14 = Get-Command Test-SealEvidenceRetention -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 retention validator exists" $t14

$cmd15 = Get-Command Test-SealRetentionIntegrity -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 retention integrity validator exists" $t15

$cmd16 = Get-Command Test-SealRetentionScope -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 retention scope validator exists" $t16

# ============================================================
# CONTROLLED EVIDENCE RETENTION
# ============================================================

$EvidenceId = "EVIDENCE-8A44-001"
$SealId = "SEAL-8A44-001"
$EvidenceHash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$ExecutionId = "EXEC-8A44-001"

$registration = Register-SealEvidenceRetention `
    -EvidenceId $EvidenceId `
    -SealId $SealId `
    -EvidenceHash $EvidenceHash `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -EvidenceStatus "VALID" `
    -PermanentEvidence $true `
    -ImmutableEvidence $true `
    -IntegrityValid $true

$records = @(Get-SealRetentionRecords)

# ============================================================
# 17-24
# ============================================================

$t17 = (
    $registration.Allowed -eq $true -and
    $registration.Code -eq "EVIDENCE_RETENTION_REGISTERED"
)
Add-Test "17 evidence retention registered" $t17

$t18 = (
    $records.Count -eq 1 -and
    $records[0].RetentionState -eq "RETAINED" -and
    $records[0].AvailabilityState -eq "AVAILABLE"
)
Add-Test "18 retained and available state persisted" $t18

$t19 = (
    $records[0].PermanentEvidence -eq $true -and
    $records[0].ImmutableEvidence -eq $true -and
    $records[0].IntegrityValid -eq $true
)
Add-Test "19 permanent immutable integrity flags valid" $t19

$t20 = (
    $records[0].DeletionAllowed -eq $false -and
    $records[0].MutationAllowed -eq $false -and
    $records[0].RewriteAllowed -eq $false
)
Add-Test "20 deletion mutation rewrite blocked" $t20

$t21 = (
    $records[0].PrematureExpiry -eq $false -and
    $records[0].RetentionBypass -eq $false
)
Add-Test "21 premature expiry and retention bypass blocked" $t21

$retention = Test-SealEvidenceRetention `
    -RetentionId $registration.RetentionId

$t22 = (
    $retention.Allowed -eq $true -and
    $retention.Decision -eq "ALLOW" -and
    $retention.Code -eq "SEAL_EVIDENCE_RETAINED"
)
Add-Test "22 retention validation succeeds" $t22

$scope = Test-SealRetentionScope `
    -RetentionId $registration.RetentionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId

$t23 = (
    $scope.Allowed -eq $true -and
    $scope.Code -eq "SEAL_RETENTION_SCOPE_VALID"
)
Add-Test "23 retention scope validated" $t23

$integrity = Test-SealRetentionIntegrity

$rawState = Get-Content `
    -LiteralPath "$Root\state\retention.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "SEAL_RETENTION_INTEGRITY_VALID" -and
    $records[0].RetentionHash.Length -eq 64 -and
    $records[0].RetentionId -ne $null -and
    $records[0].EvidenceId -eq $EvidenceId -and
    $records[0].SealId -eq $SealId -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 retention integrity scope and secrets protection valid" $t24

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
Write-Host "RESULTAT 8A-44 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-44 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-44 : ECHEC - NE PAS PASSER A 8A-45" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
