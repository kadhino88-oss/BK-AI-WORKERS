$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Revocation-Closure.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-22 CREDENTIAL REVOCATION CLOSURE & STALE BINDING GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRevocationClosure

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

$CredentialRef = "cred:test:closure"
$LeaseId = "LEASE-8A22-001"
$MaterializationId = "MAT-8A22-001"
$UsageId = "USE-8A22-001"
$ExecutionId = "EXEC-8A22-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "CONTROLLED-API"
$ProjectId = "PROJECT-001"
$ClientId = "CLIENT-001"
$TenantId = "TENANT-001"

# ============================================================
# 01-12 CONFIG
# ============================================================

$config = Get-CredentialRevocationClosureConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.closureGuardEnabled -eq $true
Add-Test "02 closure guard enabled" $t02

$t03 = $config.staleBindingGuardEnabled -eq $true
Add-Test "03 stale binding guard enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireCredentialBinding -eq $true
Add-Test "05 credential binding required" $t05

$t06 = $config.requireLeaseBinding -eq $true
Add-Test "06 lease binding required" $t06

$t07 = $config.requireMaterializationBinding -eq $true
Add-Test "07 materialization binding required" $t07

$t08 = $config.requireUsageBinding -eq $true
Add-Test "08 usage binding required" $t08

$t09 = $config.requireExecutionBinding -eq $true
Add-Test "09 execution binding required" $t09

$t10 = $config.requireWorkerBinding -eq $true
Add-Test "10 worker binding required" $t10

$t11 = $config.requireActionBinding -eq $true
Add-Test "11 action binding required" $t11

$t12 = $config.blockReactivation -eq $true
Add-Test "12 reactivation blocked by policy" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command New-CredentialRevocationClosure -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 closure constructor exists" $t13

$cmd14 = Get-Command Test-CredentialRevocationClosure -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 closure validator exists" $t14

$cmd15 = Get-Command Close-CredentialRevocationClosure -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 closure finalizer exists" $t15

$cmd16 = Get-Command Test-CredentialReactivation -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 reactivation validator exists" $t16

# ============================================================
# CREATE CLOSURE
# ============================================================

$closure = New-CredentialRevocationClosure `
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

$record = Get-CredentialRevocationClosureRecord `
    -ClosureId $closure.ClosureId

# ============================================================
# 17-24 SECURITY / CLOSURE
# ============================================================

$t17 = $closure.Allowed -eq $true
Add-Test "17 closure created" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($closure.ClosureId)
Add-Test "18 closure id generated" $t18

$t19 = $record.ClosureHash.Length -eq 64
Add-Test "19 closure hash SHA256" $t19

$t20 = (
    $record.CredentialStatus -eq "REVOKED" -and
    $record.LeaseStatus -eq "REVOKED" -and
    $record.MaterializationStatus -eq "REVOKED" -and
    $record.UsageStatus -eq "REVOKED" -and
    $record.ExecutionStatus -eq "CLOSED" -and
    $record.Status -eq "CLOSED" -and
    $record.Decision -eq "BLOCK"
)
Add-Test "20 complete closure state persisted" $t20

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t21 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "21 raw secret never persisted" $t21

$t22 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "22 raw credential never persisted" $t22

$reactivation = Test-CredentialReactivation `
    -ClosureId $closure.ClosureId

$t23 = (
    $reactivation.Allowed -eq $false -and
    $reactivation.Code -eq "REACTIVATION_BLOCKED"
)
Add-Test "23 reactivation blocked" $t23

$validation = Test-CredentialRevocationClosure `
    -ClosureId $closure.ClosureId `
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
    $validation.Allowed -eq $false -and
    $validation.Code -eq "CLOSED"
)

Add-Test "24 stale binding blocked after closure" $t24

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
Write-Host "RESULTAT 8A-22 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-22 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-22 : ECHEC - NE PAS PASSER A 8A-23" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
