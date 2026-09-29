$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Credential-Revocation-Audit.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-21 CREDENTIAL REVOCATION AUDIT & TRACE GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-CredentialRevocationAudit

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

$CredentialRef = "cred:test:audit"
$LeaseId = "LEASE-8A21-001"
$MaterializationId = "MAT-8A21-001"
$UsageId = "USE-8A21-001"
$ExecutionId = "EXEC-8A21-001"
$WorkerId = "SAM"
$Action = "CONNECTOR_USE"
$Connector = "AUDIT-API"
$ProjectId = "PROJECT-001"
$ClientId = "CLIENT-001"
$TenantId = "TENANT-001"
$Reason = "SECURITY_REVOKED"

# ============================================================
# 01-12 CONFIG
# ============================================================

$config = Get-CredentialRevocationAuditConfig

$t01 = $config.enabled -eq $true
Add-Test "01 config enabled" $t01

$t02 = $config.auditEnabled -eq $true
Add-Test "02 audit enabled" $t02

$t03 = $config.traceCorrelationEnabled -eq $true
Add-Test "03 trace correlation enabled" $t03

$t04 = $config.hashChainEnabled -eq $true
Add-Test "04 hash chain enabled" $t04

$t05 = $config.immutableEventsEnabled -eq $true
Add-Test "05 immutable events enabled" $t05

$t06 = $config.failClosed -eq $true
Add-Test "06 fail closed enabled" $t06

$t07 = $config.requireCredentialBinding -eq $true
Add-Test "07 credential binding required" $t07

$t08 = $config.requireLeaseBinding -eq $true
Add-Test "08 lease binding required" $t08

$t09 = $config.requireMaterializationBinding -eq $true
Add-Test "09 materialization binding required" $t09

$t10 = $config.requireUsageBinding -eq $true
Add-Test "10 usage binding required" $t10

$t11 = $config.requireExecutionBinding -eq $true
Add-Test "11 execution binding required" $t11

$t12 = $config.requireTenantBinding -eq $true
Add-Test "12 tenant binding required" $t12

# ============================================================
# 13-15 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Write-CredentialRevocationAuditEvent -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 audit writer exists" $t13

$cmd14 = Get-Command Test-CredentialRevocationAuditIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 audit integrity validator exists" $t14

$cmd15 = Get-Command Test-CredentialRevocationAuditChain -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 audit chain validator exists" $t15

# ============================================================
# FIRST EVENT
# ============================================================

$event1 = Write-CredentialRevocationAuditEvent `
    -EventType "CREDENTIAL_REVOKED" `
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
    -TenantId $TenantId `
    -Decision "BLOCK" `
    -Reason $Reason

$record1 = Get-CredentialRevocationAuditRecord `
    -EventId $event1.EventId

# ============================================================
# 16-24 FIRST EVENT SECURITY
# ============================================================

$t16 = $event1.Allowed -eq $true
Add-Test "16 audit event created" $t16

$t17 = -not [string]::IsNullOrWhiteSpace($event1.EventId)
Add-Test "17 event id generated" $t17

$t18 = $event1.EventHash.Length -eq 64
Add-Test "18 event hash SHA256" $t18

$t19 = $event1.PreviousEventHash -eq "GENESIS"
Add-Test "19 first event linked to genesis" $t19

$t20 = $record1.Immutable -eq $true
Add-Test "20 event marked immutable" $t20

$statePath = Join-Path $Root "state\records.json"
$rawState = Get-Content -LiteralPath $statePath -Raw

$t21 = $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+'
Add-Test "21 raw secret never persisted" $t21

$t22 = $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
Add-Test "22 raw credential never persisted" $t22

$integrity = Test-CredentialRevocationAuditIntegrity `
    -EventId $event1.EventId

$t23 = $integrity.Allowed -eq $true
Add-Test "23 event integrity valid" $t23

# ============================================================
# SECOND EVENT — CHAIN LINK
# ============================================================

$event2 = Write-CredentialRevocationAuditEvent `
    -EventType "USAGE_BLOCKED" `
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
    -TenantId $TenantId `
    -Decision "BLOCK" `
    -Reason "REVOCATION_PROPAGATED"

$chain = Test-CredentialRevocationAuditChain

$record2 = Get-CredentialRevocationAuditRecord `
    -EventId $event2.EventId

$t24 = (
    $chain.Allowed -eq $true -and
    $chain.Count -eq 2 -and
    $record2.PreviousEventHash -eq $event1.EventHash -and
    $record2.EventHash.Length -eq 64
)

Add-Test "24 hash chain correlation valid" $t24

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
Write-Host "RESULTAT 8A-21 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-21 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-21 : ECHEC - NE PAS PASSER A 8A-22" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
