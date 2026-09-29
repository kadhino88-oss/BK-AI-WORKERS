$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Activation.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-26 CREDENTIAL RECOVERY FRESH-CHAIN ACTIVATION GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryActivation

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

$AuthorizationId = "RAUTH-8A26-001"
$ContextId = "CTX-8A26-001"
$OldChainId = "CHAIN-8A26-OLD"
$NewChainId = "CHAIN-8A26-NEW"
$NewLeaseId = "LEASE-8A26-NEW"
$NewMaterializationId = "MAT-8A26-NEW"
$NewUsageId = "USE-8A26-NEW"
$NewExecutionId = "EXEC-8A26-NEW"
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

$config = Get-CredentialRecoveryActivationConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.activationGuardEnabled -eq $true
Add-Test "02 activation guard enabled" $t02

$t03 = $config.requireRecoveryAuthorization -eq $true
Add-Test "03 recovery authorization required" $t03

$t04 = $config.requireContextRevalidation -eq $true
Add-Test "04 context revalidation required" $t04

$t05 = $config.requireFreshChain -eq $true
Add-Test "05 fresh chain required" $t05

$t06 = $config.requireFreshLease -eq $true
Add-Test "06 fresh lease required" $t06

$t07 = $config.requireFreshMaterialization -eq $true
Add-Test "07 fresh materialization required" $t07

$t08 = $config.requireFreshUsage -eq $true
Add-Test "08 fresh usage required" $t08

$t09 = $config.requireFreshExecution -eq $true
Add-Test "09 fresh execution required" $t09

$t10 = $config.blockOldChainReuse -eq $true
Add-Test "10 old chain reuse blocked" $t10

$t11 = $config.blockCrossTenantActivation -eq $true
Add-Test "11 cross tenant activation blocked" $t11

$t12 = $config.singleUseActivationEnabled -eq $true
Add-Test "12 single use activation enabled" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Activate-FreshCredentialRecoveryChain -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 activation function exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryActivation -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 activation validator exists" $t14

$cmd15 = Get-Command Consume-CredentialRecoveryActivation -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 activation consume exists" $t15

$cmd16 = Get-Command Reset-CredentialRecoveryActivation -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 reset exists" $t16

# ============================================================
# ACTIVATE FRESH CHAIN
# ============================================================

$activation = Activate-FreshCredentialRecoveryChain `
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

$record = Get-CredentialRecoveryActivationRecord `
    -ActivationId $activation.ActivationId

# ============================================================
# 17-24 SECURITY
# ============================================================

$t17 = $activation.Allowed -eq $true
Add-Test "17 fresh chain activation allowed" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($activation.ActivationId)
Add-Test "18 activation id generated" $t18

$t19 = $activation.ActivationHash.Length -eq 64
Add-Test "19 activation hash SHA256" $t19

$t20 = (
    $record.Status -eq "ACTIVE" -and
    $record.Decision -eq "ALLOW" -and
    $record.NewChainId -eq $NewChainId -and
    $record.NewLeaseId -eq $NewLeaseId -and
    $record.NewMaterializationId -eq $NewMaterializationId -and
    $record.NewUsageId -eq $NewUsageId -and
    $record.NewExecutionId -eq $NewExecutionId
)
Add-Test "20 fresh activation state persisted" $t20

$t21 = (
    $record.OldChainId -eq $OldChainId -and
    $record.OldChainId -ne $record.NewChainId
)
Add-Test "21 old chain and new chain are distinct" $t21

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t22 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "22 raw secret never persisted" $t22

$t23 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "23 raw credential never persisted" $t23

$validation = Test-CredentialRecoveryActivation `
    -ActivationId $activation.ActivationId `
    -AuthorizationId $AuthorizationId `
    -ContextId $ContextId `
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

$consume = Consume-CredentialRecoveryActivation `
    -ActivationId $activation.ActivationId

$afterConsume = Get-CredentialRecoveryActivationRecord `
    -ActivationId $activation.ActivationId

$t24 = (
    $validation.Allowed -eq $true -and
    $validation.Code -eq "AUTHORIZED" -and
    $consume.Status -eq "CONSUMED" -and
    $afterConsume.Status -eq "CONSUMED" -and
    $afterConsume.Decision -eq "BLOCK"
)

Add-Test "24 activation validated and consumed once" $t24

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
Write-Host "RESULTAT 8A-26 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-26 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-26 : ECHEC - NE PAS PASSER A 8A-27" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
