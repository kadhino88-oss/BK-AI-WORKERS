Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-completion"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Completion.ps1"
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

Reset-DeliveryCompletion

$Receipt = [pscustomobject][ordered]@{
    ReceiptId      = "RECEIPT-7H64-001"
    DeliveryId     = "DELIVERY-7H64-001"
    ExecutionId    = "EXEC-7H64-001"
    TenantId       = "TENANT-001"
    ClientId       = "CLIENT-001"
    ProjectId      = "PROJECT-001"
    TargetId       = "TARGET-001"
    Channel        = "INTERNAL"
    ConfirmedAtUtc = [DateTime]::UtcNow.ToString("o")
    Status         = "CONFIRMED"
}

$Base = @{
    Receipt     = $Receipt
    DeliveryId  = "DELIVERY-7H64-001"
    ExecutionId = "EXEC-7H64-001"
    TenantId    = "TENANT-001"
    ClientId    = "CLIENT-001"
    ProjectId   = "PROJECT-001"
    TargetId    = "TARGET-001"
}

Invoke-Test "01 config enabled" {
    (Get-DeliveryCompletionConfig).enabled -eq $true
}

Invoke-Test "02 completion guard enabled" {
    (Get-DeliveryCompletionConfig).completionGuardEnabled -eq $true
}

Invoke-Test "03 confirmed receipt required" {
    (Get-DeliveryCompletionConfig).requireConfirmedReceipt -eq $true
}

Invoke-Test "04 initial state empty" {
    @(Get-DeliveryCompletionState).Count -eq 0
}

Invoke-Test "05 valid completion allowed" {
    (Test-DeliveryCompletion @Base).Valid -eq $true
}

Invoke-Test "06 completion succeeds" {
    $R = Complete-Delivery @Base

    ($R.Success -eq $true) -and
    ($R.Completed -eq $true) -and
    ($R.Status -eq "COMPLETED")
}

Invoke-Test "07 completion persisted" {
    @(Get-DeliveryCompletionState).Count -eq 1
}

Invoke-Test "08 completion id generated" {
    -not [string]::IsNullOrWhiteSpace(
        (Complete-Delivery @Base).CompletionId
    )
}

Invoke-Test "09 duplicate completion detected" {
    $R = Complete-Delivery @Base

    ($R.Success -eq $true) -and
    ($R.Status -eq "DUPLICATE") -and
    ($R.Completed -eq $true)
}

Invoke-Test "10 duplicate completion does not add record" {
    @(Get-DeliveryCompletionState).Count -eq 1
}

Invoke-Test "11 receipt requirement enforced" {
    $R = Complete-Delivery `
        -Receipt $null `
        -DeliveryId "DELIVERY-X" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -TargetId "TARGET-X"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "RECEIPT_REQUIRED")
}

Invoke-Test "12 unconfirmed receipt blocked" {
    $BadReceipt = $Receipt.PSObject.Copy()
    $BadReceipt.Status = "PENDING"

    $R = Complete-Delivery `
        -Receipt $BadReceipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($R.Success -eq $false) -and
    ($R.Reason -eq "RECEIPT_NOT_CONFIRMED")
}

Invoke-Test "13 execution mismatch blocked" {
    $R = Complete-Delivery `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId "EXEC-OTHER" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "14 tenant mismatch blocked" {
    $R = Complete-Delivery `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId "TENANT-OTHER" `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "15 client mismatch blocked" {
    $R = Complete-Delivery `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId "CLIENT-OTHER" `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($R.Success -eq $false) -and
    ($R.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "16 project mismatch blocked" {
    $R = Complete-Delivery `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId "PROJECT-OTHER" `
        -TargetId $Base.TargetId

    ($R.Success -eq $false) -and
    ($R.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "17 target mismatch blocked" {
    $R = Complete-Delivery `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId "TARGET-OTHER"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TARGET_MISMATCH")
}

Invoke-Test "18 delivery id missing blocked" {
    $R = Complete-Delivery `
        -Receipt $Receipt `
        -DeliveryId "" `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($R.Success -eq $false) -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "19 execution id missing blocked" {
    $R = Test-DeliveryCompletion `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId "" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISSING")
}

Invoke-Test "20 target id missing blocked" {
    $R = Test-DeliveryCompletion `
        -Receipt $Receipt `
        -DeliveryId $Base.DeliveryId `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId ""

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "TARGET_ID_MISSING")
}

Invoke-Test "21 completion context persisted" {
    $Record = @(
        Get-DeliveryCompletionState |
        Where-Object {
            $_.DeliveryId -eq $Base.DeliveryId
        }
    ) | Select-Object -First 1

    ($Record.ExecutionId -eq $Base.ExecutionId) -and
    ($Record.TenantId -eq $Base.TenantId) -and
    ($Record.ClientId -eq $Base.ClientId) -and
    ($Record.ProjectId -eq $Base.ProjectId) -and
    ($Record.TargetId -eq $Base.TargetId)
}

Invoke-Test "22 final status persisted" {
    $Record = @(
        Get-DeliveryCompletionState |
        Where-Object {
            $_.DeliveryId -eq $Base.DeliveryId
        }
    ) | Select-Object -First 1

    $Record.Status -eq "COMPLETED"
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryCompletionConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryCompletionConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-64 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"