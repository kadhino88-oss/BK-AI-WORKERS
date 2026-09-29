$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Authorization.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-24 CREDENTIAL RECOVERY AUTHORIZATION & FRESH-CHAIN BINDING" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryAuthorization

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

# ============================================================
# PARENT FIXTURE
# ============================================================
#
# Nous créons explicitement un état 8A-23 minimal dans son
# propre state file. 8A-24 le lira comme en production.
#

$recoveryRoot = Join-Path `
    (Split-Path $Root -Parent) `
    "credential-revocation-recovery"

$recoveryStateRoot = Join-Path $recoveryRoot "state"

New-Item `
    -ItemType Directory `
    -Force `
    -Path $recoveryStateRoot | Out-Null

$ParentRecoveryId = "REC-8A24-PARENT"
$ParentChainId = "CHAIN-8A24-OLD"

$parentFixture = [pscustomobject][ordered]@{
    RecoveryId = $ParentRecoveryId
    ChainId = $ParentChainId
    UserId = "USER-001"
    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"
    ChainStatus = "REVOKED"
    RecoveryStatus = "CLOSED"
    ReactivationAllowed = $false
}

$parentJson = ConvertTo-Json `
    -InputObject @($parentFixture) `
    -Depth 20

Set-Content `
    -LiteralPath "$recoveryStateRoot\records.json" `
    -Value $parentJson `
    -Encoding UTF8

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

$config = Get-CredentialRecoveryAuthorizationConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.recoveryAuthorizationEnabled -eq $true
Add-Test "02 recovery authorization enabled" $t02

$t03 = $config.freshChainBindingEnabled -eq $true
Add-Test "03 fresh chain binding enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireParentRecoveryReference -eq $true
Add-Test "05 parent recovery reference required" $t05

$t06 = $config.requireUserBinding -eq $true
Add-Test "06 user binding required" $t06

$t07 = $config.requireTenantBinding -eq $true
Add-Test "07 tenant binding required" $t07

$t08 = $config.requireClientBinding -eq $true
Add-Test "08 client binding required" $t08

$t09 = $config.requireProjectBinding -eq $true
Add-Test "09 project binding required" $t09

$t10 = $config.requireWorkerBinding -eq $true
Add-Test "10 worker binding required" $t10

$t11 = $config.requireActionBinding -eq $true
Add-Test "11 action binding required" $t11

$t12 = $config.blockContextSubstitution -eq $true
Add-Test "12 context substitution blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Authorize-CredentialRecovery -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 recovery authorization function exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryAuthorization -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 recovery authorization validator exists" $t14

$cmd15 = Get-Command Consume-CredentialRecoveryAuthorization -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 recovery authorization consume exists" $t15

$cmd16 = Get-Command Get-ParentRecoveryRecord -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 explicit 8A-23 parent lookup exists" $t16

# ============================================================
# CREATE AUTHORIZATION
# ============================================================

$authorization = Authorize-CredentialRecovery `
    -ParentRecoveryId $ParentRecoveryId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector

$record = Get-CredentialRecoveryAuthorizationRecord `
    -AuthorizationId $authorization.AuthorizationId

# ============================================================
# 17-24
# ============================================================

$t17 = $authorization.Allowed -eq $true
Add-Test "17 recovery authorization allowed" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($authorization.AuthorizationId)
Add-Test "18 authorization id generated" $t18

$t19 = $authorization.AuthorizationHash.Length -eq 64
Add-Test "19 authorization hash SHA256" $t19

$t20 = (
    $record.ParentRecoveryId -eq $ParentRecoveryId -and
    $record.ParentChainId -eq $ParentChainId -and
    $record.UserId -eq $UserId -and
    $record.TenantId -eq $TenantId -and
    $record.ClientId -eq $ClientId -and
    $record.ProjectId -eq $ProjectId -and
    $record.AuthorizationStatus -eq "AUTHORIZED" -and
    $record.Decision -eq "ALLOW"
)
Add-Test "20 parent and context binding persisted" $t20

$t21 = (
    -not [string]::IsNullOrWhiteSpace($record.NewChainId) -and
    -not [string]::IsNullOrWhiteSpace($record.NewLeaseId) -and
    -not [string]::IsNullOrWhiteSpace($record.NewMaterializationId) -and
    -not [string]::IsNullOrWhiteSpace($record.NewUsageId) -and
    -not [string]::IsNullOrWhiteSpace($record.NewExecutionId)
)
Add-Test "21 complete fresh chain identifiers generated" $t21

$rawState = Get-Content `
    -LiteralPath "$Root\state\records.json" `
    -Raw

$t22 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "22 raw secret never persisted" $t22

$t23 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "23 raw credential never persisted" $t23

$validation = Test-CredentialRecoveryAuthorization `
    -AuthorizationId $authorization.AuthorizationId `
    -ParentRecoveryId $ParentRecoveryId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector

$consume = Consume-CredentialRecoveryAuthorization `
    -AuthorizationId $authorization.AuthorizationId

$afterConsume = Get-CredentialRecoveryAuthorizationRecord `
    -AuthorizationId $authorization.AuthorizationId

$t24 = (
    $validation.Allowed -eq $true -and
    $consume.Status -eq "CONSUMED" -and
    $afterConsume.AuthorizationStatus -eq "CONSUMED" -and
    $afterConsume.Decision -eq "BLOCK"
)
Add-Test "24 authorization validated and consumed once" $t24

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
Write-Host "RESULTAT 8A-24 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-24 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-24 : ECHEC - NE PAS PASSER A 8A-25" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
