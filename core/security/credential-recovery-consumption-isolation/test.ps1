$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Consumption-Isolation.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-35 CONSUMPTION AUTHORIZATION & TENANT ISOLATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-ConsumptionIsolation

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

$config = Get-ConsumptionIsolationConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 isolation module enabled" $t01

$t02 = $config.authorizationEnabled -eq $true
Add-Test "02 authorization enabled" $t02

$t03 = $config.tenantIsolationEnabled -eq $true
Add-Test "03 tenant isolation enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireEnforcementBinding -eq $true
Add-Test "05 enforcement binding required" $t05

$t06 = $config.requireRecoveryBinding -eq $true
Add-Test "06 recovery binding required" $t06

$t07 = $config.requireExecutionBinding -eq $true
Add-Test "07 execution binding required" $t07

$t08 = $config.requireContextBinding -eq $true
Add-Test "08 context binding required" $t08

$t09 = $config.requireTenantBinding -eq $true
Add-Test "09 tenant binding required" $t09

$t10 = $config.requireClientBinding -eq $true
Add-Test "10 client binding required" $t10

$t11 = $config.requireProjectBinding -eq $true
Add-Test "11 project binding required" $t11

$t12 = $config.requireContextHash -eq $true
Add-Test "12 context hash required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Authorize-FinalEnforcementConsumption -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 consumption authorization exists" $t13

$cmd14 = Get-Command Test-ConsumptionAuthorizationIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 authorization integrity validator exists" $t14

$cmd15 = Get-Command Test-ConsumptionTenantIsolation -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 tenant isolation validator exists" $t15

$cmd16 = Get-Command New-ConsumptionContextHash -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 context hash generator exists" $t16

# ============================================================
# CONTROLLED AUTHORIZATION
# ============================================================

$EnforcementId = "ENF-8A35-001"
$RecoveryId = "REC-8A35-001"
$ConsumptionId = "CONSUME-8A35-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$UserId = "USER-001"
$WorkerId = "SAM"

$ExecutionId = "EXEC-8A35-001"
$Action = "CONNECTOR_USE"
$Connector = "CONTROLLED-API"

$ContextHash = New-ConsumptionContextHash `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector

$authorization = Authorize-FinalEnforcementConsumption `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -ConsumptionId $ConsumptionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId `
    -ExecutionId $ExecutionId `
    -Action $Action `
    -Connector $Connector `
    -ContextHash $ContextHash `
    -Enforced $true `
    -Consumed $true `
    -ReplayBlocked $true `
    -PermanentLock $true `
    -Immutable $true

$records = @(Get-AuthorizedConsumptionRecords)

# ============================================================
# 17-24
# ============================================================

$t17 = $authorization.Allowed -eq $true
Add-Test "17 valid consumption authorization allowed" $t17

$t18 = $authorization.Decision -eq "ALLOW"
Add-Test "18 authorization decision allow" $t18

$t19 = $authorization.TenantIsolated -eq $true
Add-Test "19 tenant isolated" $t19

$t20 = (
    $records.Count -eq 1 -and
    $records[0].AuthorizationStatus -eq "AUTHORIZED"
)
Add-Test "20 authorization persisted" $t20

$t21 = (
    $records[0].TenantId -eq $TenantId -and
    $records[0].ClientId -eq $ClientId -and
    $records[0].ProjectId -eq $ProjectId
)
Add-Test "21 tenant client project binding preserved" $t21

$t22 = (
    $records[0].UserId -eq $UserId -and
    $records[0].WorkerId -eq $WorkerId -and
    $records[0].Action -eq $Action -and
    $records[0].Connector -eq $Connector
)
Add-Test "22 user worker action connector binding preserved" $t22

$scope = Test-ConsumptionTenantIsolation `
    -AuthorizationId $authorization.AuthorizationId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector

$t23 = (
    $scope.Allowed -eq $true -and
    $scope.Decision -eq "ALLOW" -and
    $scope.Code -eq "CONSUMPTION_SCOPE_VALID"
)
Add-Test "23 matching scope accepted" $t23

$integrity = Test-ConsumptionAuthorizationIntegrity

$rawState = Get-Content `
    -LiteralPath "$Root\state\authorized-consumptions.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "CONSUMPTION_AUTHORIZATION_INTEGRITY_VALID" -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "24 authorization integrity valid and secrets absent" $t24

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
Write-Host "RESULTAT 8A-35 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-35 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-35 : ECHEC - NE PAS PASSER A 8A-36" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
