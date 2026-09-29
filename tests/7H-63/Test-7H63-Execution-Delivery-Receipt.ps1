Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-receipt"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Receipt.ps1"
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

Reset-DeliveryReceipts

$Base = @{
    DeliveryId = "DELIVERY-7H63-001"
    ExecutionId = "EXEC-7H63-001"
    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"
    TargetId = "TARGET-001"
    Channel = "INTERNAL"
}

Invoke-Test "01 config enabled" {
    (Get-DeliveryReceiptConfig).enabled -eq $true
}

Invoke-Test "02 receipt guard enabled" {
    (Get-DeliveryReceiptConfig).receiptGuardEnabled -eq $true
}

Invoke-Test "03 confirmation required" {
    (Get-DeliveryReceiptConfig).confirmationRequired -eq $true
}

Invoke-Test "04 state initially empty" {
    @(Get-DeliveryReceiptState).Count -eq 0
}

Invoke-Test "05 confirmation succeeds" {
    $R = Confirm-Delivery @Base
    ($R.Success -eq $true) -and
    ($R.Confirmed -eq $true) -and
    ($R.Status -eq "CONFIRMED")
}

Invoke-Test "06 receipt persisted" {
    @(Get-DeliveryReceiptState).Count -eq 1
}

Invoke-Test "07 receipt is valid" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    (Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId).Valid -eq $true
}

Invoke-Test "08 duplicate confirmation blocked" {
    $R = Confirm-Delivery @Base

    ($R.Success -eq $true) -and
    ($R.Status -eq "DUPLICATE")
}

Invoke-Test "09 duplicate does not add receipt" {
    @(Get-DeliveryReceiptState).Count -eq 1
}

Invoke-Test "10 delivery mismatch blocked" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    $Check = Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId "DELIVERY-OTHER" `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "DELIVERY_ID_MISMATCH")
}

Invoke-Test "11 execution mismatch blocked" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    $Check = Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId "EXEC-OTHER" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "12 tenant mismatch blocked" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    $Check = Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId "TENANT-OTHER" `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "13 client mismatch blocked" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    $Check = Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId "CLIENT-OTHER" `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "14 project mismatch blocked" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    $Check = Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId "PROJECT-OTHER" `
        -TargetId $Base.TargetId

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "15 target mismatch blocked" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    $Check = Test-DeliveryReceipt `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId "TARGET-OTHER"

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "TARGET_MISMATCH")
}

Invoke-Test "16 missing delivery blocked" {
    $R = Confirm-Delivery `
        -DeliveryId "" `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId `
        -Channel $Base.Channel

    ($R.Success -eq $false) -and
    ($R.Status -eq "BLOCKED") -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "17 missing execution blocked" {
    $R = Confirm-Delivery `
        -DeliveryId "DELIVERY-X" `
        -ExecutionId "" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId `
        -Channel $Base.Channel

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISSING")
}

Invoke-Test "18 missing target blocked" {
    $R = Confirm-Delivery `
        -DeliveryId "DELIVERY-X2" `
        -ExecutionId "EXEC-X2" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId "" `
        -Channel $Base.Channel

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TARGET_ID_MISSING")
}

Invoke-Test "19 null receipt blocked" {
    $Check = Test-DeliveryReceipt `
        -Receipt $null `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "RECEIPT_NULL")
}

Invoke-Test "20 receipt fields preserved" {
    $Receipt = Find-DeliveryReceipt -DeliveryId $Base.DeliveryId

    ($Receipt.TenantId -eq $Base.TenantId) -and
    ($Receipt.ClientId -eq $Base.ClientId) -and
    ($Receipt.ProjectId -eq $Base.ProjectId) -and
    ($Receipt.TargetId -eq $Base.TargetId)
}

Invoke-Test "21 receipt execution preserved" {
    (Find-DeliveryReceipt -DeliveryId $Base.DeliveryId).ExecutionId -eq $Base.ExecutionId
}

Invoke-Test "22 receipt status confirmed" {
    (Find-DeliveryReceipt -DeliveryId $Base.DeliveryId).Status -eq "CONFIRMED"
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryReceiptConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryReceiptConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-63 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"