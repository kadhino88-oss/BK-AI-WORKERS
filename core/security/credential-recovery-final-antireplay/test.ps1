$ErrorActionPreference = "Stop"

$Root = $PSScriptRoot

. "$Root\Final-Enforcement-Anti-Replay.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-34 FINAL ENFORCEMENT ANTI-REPLAY & ONE-TIME USE" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-FinalEnforcementAntiReplay

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

$config = Get-FinalEnforcementAntiReplayConfig

# ============================================================
# 01-12 CONFIG
# ============================================================

$t01 = $config.enabled -eq $true
Add-Test "01 anti-replay module enabled" $t01

$t02 = $config.antiReplayEnabled -eq $true
Add-Test "02 anti-replay enabled" $t02

$t03 = $config.oneTimeUseEnabled -eq $true
Add-Test "03 one-time use enabled" $t03

$t04 = $config.failClosed -eq $true
Add-Test "04 fail closed enabled" $t04

$t05 = $config.requireEnforcedState -eq $true
Add-Test "05 enforced state required" $t05

$t06 = $config.requireExecutionBinding -eq $true
Add-Test "06 execution binding required" $t06

$t07 = $config.requireContextBinding -eq $true
Add-Test "07 context binding required" $t07

$t08 = $config.requireTenantBinding -eq $true
Add-Test "08 tenant binding required" $t08

$t09 = $config.requireFreshNonce -eq $true
Add-Test "09 fresh nonce required" $t09

$t10 = $config.requireIntegrityHash -eq $true
Add-Test "10 integrity hash required" $t10

$t11 = $config.blockReplay -eq $true
Add-Test "11 replay blocked" $t11

$t12 = $config.blockExecutionReuse -eq $true
Add-Test "12 execution reuse blocked" $t12

# ============================================================
# 13-16 FUNCTIONS
# ============================================================

$cmd13 = Get-Command Invoke-FinalEnforcementConsumption -ErrorAction SilentlyContinue
$t13 = $null -ne $cmd13
Add-Test "13 consumption function exists" $t13

$cmd14 = Get-Command Test-FinalEnforcementReplay -ErrorAction SilentlyContinue
$t14 = $null -ne $cmd14
Add-Test "14 replay validator exists" $t14

$cmd15 = Get-Command Test-FinalEnforcementConsumptionIntegrity -ErrorAction SilentlyContinue
$t15 = $null -ne $cmd15
Add-Test "15 consumption integrity validator exists" $t15

$cmd16 = Get-Command New-FinalEnforcementNonce -ErrorAction SilentlyContinue
$t16 = $null -ne $cmd16
Add-Test "16 nonce generator exists" $t16

# ============================================================
# CONTROLLED COMPLETE ENFORCEMENT
# ============================================================

$EnforcementId = "ENF-8A34-001"
$RecoveryId = "REC-8A34-001"

$TenantId = "TENANT-001"
$ClientId = "CLIENT-001"
$ProjectId = "PROJECT-001"
$UserId = "USER-001"
$WorkerId = "SAM"

$ExecutionId = "EXEC-8A34-001"
$Action = "CONNECTOR_USE"
$Connector = "CONTROLLED-API"

$ContextHash = Get-FinalEnforcementAntiReplayHash `
    -Value "TENANT-001|CLIENT-001|PROJECT-001|USER-001|SAM|CONNECTOR_USE|CONTROLLED-API"

$Nonce = New-FinalEnforcementNonce

$consumption = Invoke-FinalEnforcementConsumption `
    -EnforcementId $EnforcementId `
    -RecoveryId $RecoveryId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -UserId $UserId `
    -WorkerId $WorkerId `
    -ExecutionId $ExecutionId `
    -Action $Action `
    -Connector $Connector `
    -ContextHash $ContextHash `
    -Nonce $Nonce `
    -Enforced $true `
    -PermanentLock $true `
    -Immutable $true `
    -FreshBinding $true

$records = @(Get-FinalEnforcementConsumptions)

# ============================================================
# 17-24
# ============================================================

$t17 = $consumption.Allowed -eq $true
Add-Test "17 first consumption allowed" $t17

$t18 = $consumption.Decision -eq "ALLOW"
Add-Test "18 consumption decision allow" $t18

$t19 = $consumption.ConsumptionStatus -eq "CONSUMED"
Add-Test "19 enforcement consumed" $t19

$t20 = (
    $consumption.ReplayBlocked -eq $true -and
    $consumption.Code -eq "ENFORCEMENT_CONSUMED_ONCE"
)
Add-Test "20 replay protection activated" $t20

$t21 = $records.Count -eq 1
Add-Test "21 exactly one consumption recorded" $t21

$t22 = (
    $records[0].OneTimeUse -eq $true -and
    $records[0].PermanentLock -eq $true -and
    $records[0].Immutable -eq $true
)
Add-Test "22 one-time immutable binding persisted" $t22

$replay = Test-FinalEnforcementReplay `
    -EnforcementId $EnforcementId

$t23 = (
    $replay.Allowed -eq $false -and
    $replay.Decision -eq "BLOCK" -and
    $replay.Code -eq "ENFORCEMENT_ALREADY_CONSUMED"
)
Add-Test "23 replay attempt blocked" $t23

$integrity = Test-FinalEnforcementConsumptionIntegrity

$rawState = Get-Content `
    -LiteralPath "$Root\state\consumptions.json" `
    -Raw

$t24 = (
    $integrity.Allowed -eq $true -and
    $integrity.Code -eq "CONSUMPTION_INTEGRITY_VALID" -and
    $rawState -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $rawState -notmatch '"RawCredential"\s*:\s*"[^"]+'
)
Add-Test "24 consumption integrity valid and secrets absent" $t24

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
Write-Host "RESULTAT 8A-34 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (
    ($total -eq 24) -and
    ($pass -eq 24) -and
    ($fail -eq 0)
) {

    Write-Host "8A-34 : VALIDEE - 24/0" -ForegroundColor Green
}
else {

    Write-Host "8A-34 : ECHEC - NE PAS PASSER A 8A-35" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
