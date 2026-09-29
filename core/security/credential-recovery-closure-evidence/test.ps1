$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Closure-Evidence-Guard.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-40 REVOCATION CLOSURE AUDIT & PERMANENT EVIDENCE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-ClosureEvidence

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

$config = Get-ClosureEvidenceConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 evidence module enabled" $t01

$t02 = $config.evidenceEnabled -eq $true
Add-Test "02 evidence enabled" $t02

$t03 = $config.auditEnabled -eq $true
Add-Test "03 audit enabled" $t03

$t04 = $config.hashChainEnabled -eq $true
Add-Test "04 hash chain enabled" $t04

$t05 = $config.failClosed -eq $true
Add-Test "05 fail closed enabled" $t05

$t06 = $config.requireConflictIdentity -eq $true
Add-Test "06 conflict identity required" $t06

$t07 = $config.requireResolutionIdentity -eq $true
Add-Test "07 resolution identity required" $t07

$t08 = $config.requireClosureIdentity -eq $true
Add-Test "08 closure identity required" $t08

$t09 = $config.requireTenantBinding -eq $true
Add-Test "09 tenant binding required" $t09

$t10 = $config.requireExecutionBinding -eq $true
Add-Test "10 execution binding required" $t10

$t11 = $config.requireRevokedState -eq $true
Add-Test "11 revoked state required" $t11

$t12 = $config.requireBlockedExecution -eq $true
Add-Test "12 blocked execution required" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Write-ClosureEvidence -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 evidence writer exists" $t13

$cmd14 = Get-Command Test-ClosureEvidenceIntegrity -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 evidence integrity validator exists" $t14

$cmd15 = Get-Command Test-ClosureEvidenceBinding -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 evidence binding validator exists" $t15

$cmd16 = Get-Command Test-ClosureEvidenceState -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 evidence state validator exists" $t16

# ============================================================
# CONTROLLED FINAL EVIDENCE
# ============================================================

$ConflictId = "CONFLICT-8A40-001"
$ResolutionId = "RESOLUTION-8A40-001"
$ClosureId = "CLOSURE-8A40-001"

$EnforcementId = "ENF-8A40-001"
$RecoveryId = "REC-8A40-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$ExecutionId = "EXEC-8A40-001"

$Evidence = Write-ClosureEvidence `
    -ConflictId $ConflictId `
    -ResolutionId $ResolutionId `
    -ClosureId $ClosureId `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -ExecutionId $ExecutionId `
    -ResolvedEnforcement "REVOKED" `
    -ResolvedConsumption "REVOKED" `
    -ResolvedAuthorization "REVOKED" `
    -ResolvedExecution "BLOCKED" `
    -ClosureStatus "CLOSED" `
    -Actor "SYSTEM"

$records = @(Get-ClosureEvidenceRecords)

# ============================================================
# 17-24
# ============================================================

$t17 = $Evidence.Allowed -eq $true
Add-Test "17 closure evidence written" $t17

$t18 = $Evidence.Decision -eq "BLOCK"
Add-Test "18 evidence decision remains block" $t18

$t19 = (
    $records.Count -eq 1 -and
    $records[0].ClosureStatus -eq "CLOSED"
)
Add-Test "19 closed evidence persisted" $t19

$t20 = (
    $records[0].ResolvedEnforcement -eq "REVOKED" -and
    $records[0].ResolvedConsumption -eq "REVOKED" -and
    $records[0].ResolvedAuthorization -eq "REVOKED" -and
    $records[0].ResolvedExecution -eq "BLOCKED"
)
Add-Test "20 final recovery state captured" $t20

$t21 = (
    $records[0].Immutable -eq $true -and
    $records[0].AppendOnly -eq $true -and
    $records[0].PermanentEvidence -eq $true
)
Add-Test "21 permanent immutable evidence enabled" $t21

$t22 = (
    $records[0].MutationAllowed -eq $false -and
    $records[0].DeletionAllowed -eq $false -and
    $records[0].RewriteAllowed -eq $false
)
Add-Test "22 evidence mutation deletion rewrite blocked" $t22

$binding = Test-ClosureEvidenceBinding `
    -EvidenceId $Evidence.EvidenceId `
    -TenantId $TenantId `
    -ExecutionId $ExecutionId

$state = Test-ClosureEvidenceState `
    -EvidenceId $Evidence.EvidenceId

$t23 = (
    $binding.Allowed -eq $true -and
    $binding.Code -eq "CLOSURE_EVIDENCE_SCOPE_VALID" -and
    $state.Allowed -eq $true -and
    $state.Code -eq "CLOSURE_EVIDENCE_STATE_VALID"
)
Add-Test "23 evidence binding and final state valid" $t23

$integrity = Test-ClosureEvidenceIntegrity

$rawState = Get-Content `
    -LiteralPath "$Root\state\evidence.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "CLOSURE_EVIDENCE_INTEGRITY_VALID" -and
    $integrity.EvidenceCount -eq 1 -and
    $records[0].PreviousHash -eq "GENESIS" -and
    $records[0].EvidenceHash.Length -eq 64 -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 permanent evidence integrity and secrets protection valid" $t24

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
Write-Host "RESULTAT 8A-40 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-40 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-40 : ECHEC - NE PAS PASSER A 8A-41" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
