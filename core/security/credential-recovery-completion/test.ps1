$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Completion.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-29 CREDENTIAL RECOVERY COMPLETION & STATE CONSISTENCY" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryCompletion

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

$AuthorizationId = "RAUTH-8A29-001"
$ContextId = "CTX-8A29-001"
$ActivationId = "ACT-8A29-001"
$OldChainId = "CHAIN-8A29-OLD"
$NewChainId = "CHAIN-8A29-NEW"
$NewLeaseId = "LEASE-8A29-NEW"
$NewMaterializationId = "MAT-8A29-NEW"
$NewUsageId = "USE-8A29-NEW"
$NewExecutionId = "EXEC-8A29-NEW"
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

$config = Get-CredentialRecoveryCompletionConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.completionGuardEnabled -eq $true
Add-Test "02 completion guard enabled" $t02

$t03 = $config.stateConsistencyEnabled -eq $true
Add-Test "03 state consistency enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireAuthorizationBinding -eq $true
Add-Test "05 authorization binding required" $t05

$t06 = $config.requireContextBinding -eq $true
Add-Test "06 context binding required" $t06

$t07 = $config.requireActivationBinding -eq $true
Add-Test "07 activation binding required" $t07

$t08 = $config.requireFreshChain -eq $true
Add-Test "08 fresh chain required" $t08

$t09 = $config.requireFreshLease -eq $true
Add-Test "09 fresh lease required" $t09

$t10 = $config.requireFreshMaterialization -eq $true
Add-Test "10 fresh materialization required" $t10

$t11 = $config.requireFreshUsage -eq $true
Add-Test "11 fresh usage required" $t11

$t12 = $config.requireFreshExecution -eq $true
Add-Test "12 fresh execution required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Complete-CredentialRecovery -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 completion function exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryCompletion -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 completion validator exists" $t14

$cmd15 = Get-Command Get-CredentialRecoveryCompletionRecord -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 completion lookup exists" $t15

$cmd16 = Get-Command Reset-CredentialRecoveryCompletion -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 reset exists" $t16

# ============================================================
# COMPLETE RECOVERY
# ============================================================

$completion = Complete-CredentialRecovery `
    -AuthorizationId $AuthorizationId `
    -ContextId $ContextId `
    -ActivationId $ActivationId `
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

$record = Get-CredentialRecoveryCompletionRecord `
    -CompletionId $completion.CompletionId

# ============================================================
# 17-24
# ============================================================

$t17 = $completion.Allowed -eq $true
Add-Test "17 recovery completion authorized" $t17

$t18 = -not [string]::IsNullOrWhiteSpace($completion.CompletionId)
Add-Test "18 completion id generated" $t18

$t19 = $completion.CompletionHash.Length -eq 64
Add-Test "19 completion hash SHA256" $t19

$t20 = (
    $record.CompletionStatus -eq "COMPLETED" -and
    $record.CompletionConsumed -eq $true -and
    $record.Decision -eq "ALLOW"
)
Add-Test "20 completion state persisted" $t20

$t21 = (
    $record.OldChainStatus -eq "REVOKED" -and
    $record.OldLeaseStatus -eq "REVOKED" -and
    $record.OldMaterializationStatus -eq "REVOKED" -and
    $record.OldUsageStatus -eq "REVOKED"
)
Add-Test "21 old chain remains fully revoked" $t21

$t22 = (
    $record.NewChainStatus -eq "ACTIVE" -and
    $record.NewLeaseStatus -eq "ACTIVE" -and
    $record.NewMaterializationStatus -eq "ACTIVE" -and
    $record.NewUsageStatus -eq "ACTIVE" -and
    $record.NewExecutionStatus -eq "AUTHORIZED"
)
Add-Test "22 new chain remains coherent and active" $t22

$rawState = Get-Content `
    -LiteralPath "$Root\state\records.json" `
    -Raw

$t23 = (
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "23 raw credential material never persisted" $t23

$validation = Test-CredentialRecoveryCompletion `
    -CompletionId $completion.CompletionId `
    -AuthorizationId $AuthorizationId `
    -ContextId $ContextId `
    -ActivationId $ActivationId `
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

$t24 = (
    $validation.Allowed -eq $true -and
    $validation.Code -eq "COMPLETION_VALID" -and
    $record.ReactivationAllowed -eq $false
)
Add-Test "24 completed recovery state revalidates coherently" $t24

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
Write-Host "RESULTAT 8A-29 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-29 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-29 : ECHEC - NE PAS PASSER A 8A-30" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
