$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Permanent-Lock-Audit.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-32 PERMANENT LOCK AUDIT & TAMPER GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-PermanentLockAudit

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

$config = Get-PermanentLockAuditConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 audit system enabled" $t01

$t02 = $config.auditEnabled -eq $true
Add-Test "02 audit enabled" $t02

$t03 = $config.tamperDetectionEnabled -eq $true
Add-Test "03 tamper detection enabled" $t03

$t04 = $config.hashChainEnabled -eq $true
Add-Test "04 hash chain enabled" $t04

$t05 = $config.failClosed -eq $true
Add-Test "05 fail closed enabled" $t05

$t06 = $config.requirePermanentLock -eq $true
Add-Test "06 permanent lock required" $t06

$t07 = $config.requireImmutableState -eq $true
Add-Test "07 immutable state required" $t07

$t08 = $config.requireFinalizedState -eq $true
Add-Test "08 finalized state required" $t08

$t09 = $config.blockTamperedFinalization -eq $true
Add-Test "09 tampered finalization blocked" $t09

$t10 = $config.blockAuditMutation -eq $true
Add-Test "10 audit mutation blocked" $t10

$t11 = $config.blockAuditDeletion -eq $true
Add-Test "11 audit deletion blocked" $t11

$t12 = $config.appendOnly -eq $true
Add-Test "12 append only enabled" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Write-PermanentLockAuditEvent -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 audit writer exists" $t13

$cmd14 = Get-Command Test-PermanentLockAuditIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 integrity validator exists" $t14

$cmd15 = Get-Command Test-PermanentLockAuditFinalizedState -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 finalization audit validator exists" $t15

$cmd16 = Get-Command Test-PermanentLockTamper -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 tamper validator exists" $t16

# ============================================================
# CONTROLLED AUDIT CHAIN
# ============================================================

$FinalizationId = "FINAL-8A32-001"
$RecoveryId = "REC-8A32-001"
$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$WorkerId = "SAM"
$Actor = "SYSTEM"

$event1 = Write-PermanentLockAuditEvent `
    -FinalizationId $FinalizationId `
    -RecoveryId $RecoveryId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -EventType "PERMANENT_LOCK_FINALIZED" `
    -Decision "ALLOW" `
    -Actor $Actor

$event2 = Write-PermanentLockAuditEvent `
    -FinalizationId $FinalizationId `
    -RecoveryId $RecoveryId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId $WorkerId `
    -EventType "PERMANENT_LOCK_VERIFIED" `
    -Decision "ALLOW" `
    -Actor $Actor

$events = @(Get-PermanentLockAuditEvents)

# ============================================================
# 17-24
# ============================================================

$t17 = $events.Count -eq 2
Add-Test "17 two audit events recorded" $t17

$t18 = $event1.PreviousHash -eq "GENESIS"
Add-Test "18 genesis anchor valid" $t18

$t19 = $event2.PreviousHash -eq $event1.EventHash
Add-Test "19 hash chain linkage valid" $t19

$t20 = (
    $event1.Immutable -eq $true -and
    $event2.Immutable -eq $true -and
    $event1.AppendOnly -eq $true -and
    $event2.AppendOnly -eq $true
)
Add-Test "20 immutable append-only flags valid" $t20

$t21 = (
    $event1.Decision -eq "ALLOW" -and
    $event1.EventType -eq "PERMANENT_LOCK_FINALIZED"
)
Add-Test "21 finalization event valid" $t21

$integrity = Test-PermanentLockAuditIntegrity

$t22 = (
    $integrity.Allowed -eq $true -and
    $integrity.Decision -eq "ALLOW" -and
    $integrity.Code -eq "AUDIT_INTEGRITY_VALID"
)
Add-Test "22 audit chain integrity valid" $t22

$finalized = Test-PermanentLockAuditFinalizedState `
    -FinalizationId $FinalizationId

$t23 = (
    $finalized.Allowed -eq $true -and
    $finalized.Decision -eq "ALLOW" -and
    $finalized.Code -eq "FINALIZATION_AUDITED"
)
Add-Test "23 permanent finalization is audited" $t23

$tamper = Test-PermanentLockTamper `
    -FinalizationId $FinalizationId

$t24 = (
    $tamper.Allowed -eq $true -and
    $tamper.Decision -eq "ALLOW" -and
    $tamper.Code -eq "LOCK_AUDIT_TRUSTED"
)
Add-Test "24 permanent lock audit trusted" $t24

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
Write-Host "RESULTAT 8A-32 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-32 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-32 : ECHEC - NE PAS PASSER A 8A-33" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
