$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Context.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-25 CREDENTIAL RECOVERY CONTEXT REVALIDATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryContext

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

$AuthorizationId = "RAUTH-8A25-001"
$UserId = "USER-001"
$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "CONTROLLED-API"
$NewChainId = "CHAIN-8A25-NEW"
$NewLeaseId = "LEASE-8A25-NEW"
$NewMaterializationId = "MAT-8A25-NEW"
$NewUsageId = "USE-8A25-NEW"
$NewExecutionId = "EXEC-8A25-NEW"

# ============================================================
# 01-12 CONFIG
# ============================================================

$config = Get-CredentialRecoveryContextConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.contextRevalidationEnabled -eq $true
Add-Test "02 context revalidation enabled" $t02

$t03 = $config.freshChainRequired -eq $true
Add-Test "03 fresh chain required" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireAuthorizationReference -eq $true
Add-Test "05 authorization reference required" $t05

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

$t12 = $config.requireConnectorBinding -eq $true
Add-Test "12 connector binding required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command New-RecoveryContextRecord -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 context constructor exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryContext -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 context validator exists" $t14

$cmd15 = Get-Command Revoke-CredentialRecoveryContext -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 context revoke exists" $t15

$cmd16 = Get-Command Get-CredentialRecoveryContextRecord -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 context lookup exists" $t16

# ============================================================
# CREATE CONTEXT
# ============================================================

$context = New-RecoveryContextRecord `
    -AuthorizationId $AuthorizationId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -NewChainId $NewChainId `
    -NewLeaseId $NewLeaseId `
    -NewMaterializationId $NewMaterializationId `
    -NewUsageId $NewUsageId `
    -NewExecutionId $NewExecutionId

$record = Get-CredentialRecoveryContextRecord `
    -ContextId $context.ContextId

# ============================================================
# 17-24 VALIDATION
# ============================================================

$t17 = $context.Allowed -eq $true
Add-Test "17 context authorized" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($context.ContextId)
Add-Test "18 context id generated" $t18

$t19 = $context.ContextHash.Length -eq 64
Add-Test "19 context hash SHA256" $t19

$t20 = (
    $record.Status -eq "VALID" -and
    $record.Decision -eq "ALLOW" -and
    $record.AuthorizationId -eq $AuthorizationId -and
    $record.UserId -eq $UserId -and
    $record.TenantId -eq $TenantId -and
    $record.ClientId -eq $ClientId -and
    $record.ProjectId -eq $ProjectId -and
    $record.WorkerId -eq $WorkerId -and
    $record.Action -eq $Action -and
    $record.Connector -eq $Connector
)
Add-Test "20 complete context persisted" $t20

$t21 = (
    $record.NewChainId -eq $NewChainId -and
    $record.NewLeaseId -eq $NewLeaseId -and
    $record.NewMaterializationId -eq $NewMaterializationId -and
    $record.NewUsageId -eq $NewUsageId -and
    $record.NewExecutionId -eq $NewExecutionId
)
Add-Test "21 fresh chain bindings persisted" $t21

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t22 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "22 raw secret never persisted" $t22

$t23 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "23 raw credential never persisted" $t23

$validation = Test-CredentialRecoveryContext `
    -ContextId $context.ContextId `
    -AuthorizationId $AuthorizationId `
    -UserId $UserId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -Action $Action `
    -Connector $Connector `
    -NewChainId $NewChainId `
    -NewLeaseId $NewLeaseId `
    -NewMaterializationId $NewMaterializationId `
    -NewUsageId $NewUsageId `
    -NewExecutionId $NewExecutionId

$t24 = (
    $validation.Allowed -eq $true -and
    $validation.Code -eq "CONTEXT_VALID"
)
Add-Test "24 context revalidation authorized" $t24

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
Write-Host "RESULTAT 8A-25 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-25 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-25 : ECHEC - NE PAS PASSER A 8A-26" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
