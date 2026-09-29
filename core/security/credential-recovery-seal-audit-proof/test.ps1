$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Seal-Audit-Proof.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-43 GLOBAL SECURITY SEAL AUDIT TRACE & CLOSURE PROOF" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-SealAuditProof

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

$config = Get-SealAuditProofConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 audit proof module enabled" $t01

$t02 = $config.auditEnabled -eq $true
Add-Test "02 audit enabled" $t02

$t03 = $config.closureProofEnabled -eq $true
Add-Test "03 closure proof enabled" $t03

$t04 = $config.hashChainEnabled -eq $true
Add-Test "04 hash chain enabled" $t04

$t05 = $config.failClosed -eq $true
Add-Test "05 fail closed enabled" $t05

$t06 = $config.requireSealIdentity -eq $true
Add-Test "06 seal identity required" $t06

$t07 = $config.requireTenantBinding -eq $true
Add-Test "07 tenant binding required" $t07

$t08 = $config.requireExecutionBinding -eq $true
Add-Test "08 execution binding required" $t08

$t09 = $config.requireCreateEvent -eq $true
Add-Test "09 create event required" $t09

$t10 = $config.requireActivationEvent -eq $true
Add-Test "10 activation event required" $t10

$t11 = $config.requireRevocationEvent -eq $true
Add-Test "11 revocation event required" $t11

$t12 = $config.requireClosureEvent -eq $true
Add-Test "12 closure event required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Write-SealAuditProofEvent -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 audit trace writer exists" $t13

$cmd14 = Get-Command Test-SealAuditProofIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 audit trace integrity validator exists" $t14

$cmd15 = Get-Command Test-SealLifecycleClosureProof -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 lifecycle closure proof validator exists" $t15

$cmd16 = Get-Command Test-SealAuditProofScope -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 audit scope validator exists" $t16

# ============================================================
# CONTROLLED LIFECYCLE TRACE
# ============================================================

$SealId = "SEAL-8A43-001"
$LifecycleId = "LIFE-8A43-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$ExecutionId = "EXEC-8A43-001"

$event1 = Write-SealAuditProofEvent `
    -SealId $SealId `
    -LifecycleId $LifecycleId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -EventType "SEAL_CREATED" `
    -LifecycleState "SEALED" `
    -Actor "SYSTEM"

$event2 = Write-SealAuditProofEvent `
    -SealId $SealId `
    -LifecycleId $LifecycleId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -EventType "SEAL_ACTIVATED" `
    -LifecycleState "ACTIVE" `
    -Actor "SYSTEM"

$event3 = Write-SealAuditProofEvent `
    -SealId $SealId `
    -LifecycleId $LifecycleId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -EventType "SEAL_REVOKED" `
    -LifecycleState "REVOKED" `
    -Actor "SYSTEM"

$event4 = Write-SealAuditProofEvent `
    -SealId $SealId `
    -LifecycleId $LifecycleId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -EventType "SEAL_CLOSED" `
    -LifecycleState "CLOSED" `
    -Actor "SYSTEM"

$events = @(Get-SealAuditProofEvents)

# ============================================================
# 17-24
# ============================================================

$t17 = (
    $events.Count -eq 4 -and
    $event1.EventType -eq "SEAL_CREATED"
)
Add-Test "17 complete lifecycle trace recorded" $t17

$t18 = (
    $event1.Sequence -eq 1 -and
    $event2.Sequence -eq 2 -and
    $event3.Sequence -eq 3 -and
    $event4.Sequence -eq 4
)
Add-Test "18 lifecycle sequence ordered" $t18

$t19 = (
    $event1.PreviousHash -eq "GENESIS" -and
    $event2.PreviousHash -eq $event1.EventHash -and
    $event3.PreviousHash -eq $event2.EventHash -and
    $event4.PreviousHash -eq $event3.EventHash
)
Add-Test "19 audit hash chain linked" $t19

$t20 = (
    $event1.Immutable -eq $true -and
    $event2.Immutable -eq $true -and
    $event3.Immutable -eq $true -and
    $event4.Immutable -eq $true -and
    $event1.AppendOnly -eq $true -and
    $event4.PermanentProof -eq $true
)
Add-Test "20 immutable append-only permanent proof flags valid" $t20

$integrity = Test-SealAuditProofIntegrity

$t21 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "SEAL_AUDIT_TRACE_INTEGRITY_VALID" -and
    $integrity.EventCount -eq 4
)
Add-Test "21 audit trace integrity valid" $t21

$closureProof = Test-SealLifecycleClosureProof `
    -SealId $SealId

$t22 = (
    $closureProof.Allowed -eq $true -and
    $closureProof.Decision -eq "BLOCK" -and
    $closureProof.Code -eq "SEAL_CLOSURE_PROOF_VALID"
)
Add-Test "22 lifecycle closure proof valid" $t22

$scope = Test-SealAuditProofScope `
    -SealId $SealId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId

$finalProof = Test-SealClosureProofFinality `
    -SealId $SealId

$t23 = (
    $scope.Allowed -eq $true -and
    $scope.Code -eq "SEAL_AUDIT_SCOPE_VALID" -and
    $finalProof.Allowed -eq $true -and
    $finalProof.Code -eq "SEAL_CLOSURE_FINAL_PROOF_VALID"
)
Add-Test "23 scope and closure final proof valid" $t23

$rawState = Get-Content `
    -LiteralPath "$Root\state\events.json" `
    -Raw

$t24 = (
    $events[0].SealId -eq $SealId -and
    $events[3].LifecycleState -eq "CLOSED" -and
    $events[3].PermanentProof -eq $true -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 permanent closure evidence and secrets protection valid" $t24

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
Write-Host "RESULTAT 8A-43 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-43 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-43 : ECHEC - NE PAS PASSER A 8A-44" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
