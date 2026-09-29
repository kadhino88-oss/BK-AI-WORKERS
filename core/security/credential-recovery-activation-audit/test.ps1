$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Recovery-Activation-Audit.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-28 CREDENTIAL RECOVERY ACTIVATION AUDIT & LIFECYCLE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRecoveryActivationAudit

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

$ActivationId = "ACT-8A28-001"
$AuthorizationId = "RAUTH-8A28-001"
$ContextId = "CTX-8A28-001"
$OldChainId = "CHAIN-8A28-OLD"
$NewChainId = "CHAIN-8A28-NEW"
$NewLeaseId = "LEASE-8A28-NEW"
$NewMaterializationId = "MAT-8A28-NEW"
$NewUsageId = "USE-8A28-NEW"
$NewExecutionId = "EXEC-8A28-NEW"
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

$config = Get-CredentialRecoveryActivationAuditConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.auditEnabled -eq $true
Add-Test "02 audit enabled" $t02

$t03 = $config.lifecycleGuardEnabled -eq $true
Add-Test "03 lifecycle guard enabled" $t03

$t04 = $config.correlationEnabled -eq $true
Add-Test "04 correlation enabled" $t04

$t05 = $config.hashChainEnabled -eq $true
Add-Test "05 hash chain enabled" $t05

$t06 = $config.immutableEventsEnabled -eq $true
Add-Test "06 immutable events enabled" $t06

$t07 = $config.failClosed -eq $true
Add-Test "07 fail closed enabled" $t07

$t08 = $config.requireActivationBinding -eq $true
Add-Test "08 activation binding required" $t08

$t09 = $config.requireAuthorizationBinding -eq $true
Add-Test "09 authorization binding required" $t09

$t10 = $config.requireContextBinding -eq $true
Add-Test "10 context binding required" $t10

$t11 = $config.requireNewChainBinding -eq $true
Add-Test "11 new chain binding required" $t11

$t12 = $config.requireEventCorrelation -eq $true
Add-Test "12 event correlation required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Write-CredentialRecoveryActivationAuditEvent -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 audit writer exists" $t13

$cmd14 = Get-Command Test-CredentialRecoveryActivationAuditIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 event integrity validator exists" $t14

$cmd15 = Get-Command Test-CredentialRecoveryActivationAuditChain -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 chain validator exists" $t15

$cmd16 = Get-Command Test-CredentialRecoveryActivationLifecycle -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 lifecycle validator exists" $t16

# ============================================================
# EVENT 1
# ============================================================

$e1 = Write-CredentialRecoveryActivationAuditEvent `
    -EventType "ACTIVATION_CREATED" `
    -ActivationId $ActivationId `
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
    -Connector $Connector `
    -Decision "ALLOW" `
    -Reason "ACTIVATION_CREATED"

$e2 = Write-CredentialRecoveryActivationAuditEvent `
    -EventType "ACTIVATION_VALIDATED" `
    -ActivationId $ActivationId `
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
    -Connector $Connector `
    -Decision "ALLOW" `
    -Reason "PRE_USE_VALIDATION"

$e3 = Write-CredentialRecoveryActivationAuditEvent `
    -EventType "ACTIVATION_CONSUMED" `
    -ActivationId $ActivationId `
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
    -Connector $Connector `
    -Decision "BLOCK" `
    -Reason "SINGLE_USE_CONSUMED"

# ============================================================
# 17-24
# ============================================================

$r1 = Get-CredentialRecoveryActivationAuditRecord `
    -EventId $e1.EventId

$r2 = Get-CredentialRecoveryActivationAuditRecord `
    -EventId $e2.EventId

$r3 = Get-CredentialRecoveryActivationAuditRecord `
    -EventId $e3.EventId

$t17 = $e1.Allowed -eq $true
Add-Test "17 creation event recorded" $t17

$t18 = $e1.EventHash.Length -eq 64
Add-Test "18 first event hash SHA256" $t18

$t19 = $e1.PreviousEventHash -eq "GENESIS"
Add-Test "19 first event linked to genesis" $t19

$t20 = (
    $e2.PreviousEventHash -eq $e1.EventHash -and
    $e3.PreviousEventHash -eq $e2.EventHash
)
Add-Test "20 lifecycle events correctly chained" $t20

$rawState = Get-Content -LiteralPath "$Root\state\records.json" -Raw

$t21 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "21 raw secret never persisted" $t21

$t22 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "22 raw credential never persisted" $t22

$integrity = Test-CredentialRecoveryActivationAuditIntegrity `
    -EventId $e3.EventId

$t23 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "INTEGRITY_VALID"
)
Add-Test "23 final audit event integrity valid" $t23

$chain = Test-CredentialRecoveryActivationAuditChain
$lifecycle = Test-CredentialRecoveryActivationLifecycle `
    -ActivationId $ActivationId

$t24 = (
    $chain.Allowed -eq $true -and
    $chain.Code -eq "CHAIN_VALID" -and
    $chain.Count -eq 3 -and
    $lifecycle.Allowed -eq $true -and
    $lifecycle.Code -eq "LIFECYCLE_VALID"
)
Add-Test "24 complete activation lifecycle and audit chain valid" $t24

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
Write-Host "RESULTAT 8A-28 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-28 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-28 : ECHEC - NE PAS PASSER A 8A-29" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
