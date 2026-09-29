Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-consistency"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Recovery-Consistency.ps1"
$ConfigFile = Join-Path $RuntimeRoot "config.json"

. $RuntimeFile

$Pass = 0
$Fail = 0

function Invoke-Test {

    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        $Result = & $Body

        if ($Result -eq $true) {
            Write-Host "PASS $Name" -ForegroundColor Green
            $script:Pass++
        }
        else {
            Write-Host "FAIL $Name :: ASSERTION FALSE" -ForegroundColor Red
            $script:Fail++
        }
    }
    catch {
        Write-Host "FAIL $Name :: $($_.Exception.Message)" -ForegroundColor Red
        $script:Fail++
    }
}

Reset-RecoveryConsistency

$Base = @{
    DeliveryId    = "DELIVERY-7H68-001"
    ExecutionId   = "EXEC-7H68-001"
    TenantId      = "TENANT-001"
    ClientId      = "CLIENT-001"
    ProjectId     = "PROJECT-001"
    LeaseId       = "LEASE-7H68-001"
    RetryCount    = 1
    RecoveryState = "AUTHORIZED"
}

Invoke-Test "01 config enabled" {
    (Get-DeliveryRecoveryConsistencyConfig).enabled -eq $true
}

Invoke-Test "02 consistency guard enabled" {
    (Get-DeliveryRecoveryConsistencyConfig).consistencyGuardEnabled -eq $true
}

Invoke-Test "03 lease id required" {
    (Get-DeliveryRecoveryConsistencyConfig).requireLeaseId -eq $true
}

Invoke-Test "04 initial state empty" {
    @(Get-DeliveryRecoveryConsistencyState).Count -eq 0
}

Invoke-Test "05 consistency record registered" {
    $R = Register-RecoveryConsistency @Base

    ($R.Success -eq $true) -and
    ($R.Status -eq "RECORDED")
}

Invoke-Test "06 state persisted" {
    @(Get-DeliveryRecoveryConsistencyState).Count -eq 1
}

$Record = Get-DeliveryRecoveryConsistencyState | Select-Object -First 1

Invoke-Test "07 valid recovery context" {
    $R = Test-RecoveryConsistency `
        -Record $Record `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -LeaseId $Base.LeaseId

    $R.Valid -eq $true
}

Invoke-Test "08 delivery preserved" {
    $Record.DeliveryId -eq $Base.DeliveryId
}

Invoke-Test "09 execution preserved" {
    $Record.ExecutionId -eq $Base.ExecutionId
}

Invoke-Test "10 tenant preserved" {
    $Record.TenantId -eq $Base.TenantId
}

Invoke-Test "11 client preserved" {
    $Record.ClientId -eq $Base.ClientId
}

Invoke-Test "12 project preserved" {
    $Record.ProjectId -eq $Base.ProjectId
}

Invoke-Test "13 lease preserved" {
    $Record.LeaseId -eq $Base.LeaseId
}

Invoke-Test "14 retry count preserved" {
    $Record.RetryCount -eq 1
}

Invoke-Test "15 recovery state preserved" {
    $Record.RecoveryState -eq "AUTHORIZED"
}

Invoke-Test "16 execution mismatch blocked" {
    $R = Test-RecoveryConsistency `
        -Record $Record `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId "EXEC-OTHER" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -LeaseId $Base.LeaseId

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "17 tenant mismatch blocked" {
    $R = Test-RecoveryConsistency `
        -Record $Record `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId "TENANT-OTHER" `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -LeaseId $Base.LeaseId

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "18 client mismatch blocked" {
    $R = Test-RecoveryConsistency `
        -Record $Record `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId "CLIENT-OTHER" `
        -ProjectId $Base.ProjectId `
        -LeaseId $Base.LeaseId

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "19 project mismatch blocked" {
    $R = Test-RecoveryConsistency `
        -Record $Record `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId "PROJECT-OTHER" `
        -LeaseId $Base.LeaseId

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "20 lease mismatch blocked" {
    $R = Test-RecoveryConsistency `
        -Record $Record `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -LeaseId "LEASE-OTHER"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "LEASE_MISMATCH")
}

Invoke-Test "21 null record blocked" {
    $R = Test-RecoveryConsistency `
        -Record $null `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -LeaseId $Base.LeaseId

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "RECORD_NULL")
}

Invoke-Test "22 missing delivery blocked" {
    $R = Register-RecoveryConsistency `
        -DeliveryId "" `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -LeaseId $Base.LeaseId `
        -RetryCount 0 `
        -RecoveryState "FAILED"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryRecoveryConsistencyConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryRecoveryConsistencyConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-68 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"