Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Recovery.ps1"
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

Reset-DeliveryRecovery

Invoke-Test "01 config enabled" {
    (Get-DeliveryRecoveryConfig).enabled -eq $true
}

Invoke-Test "02 recovery enabled" {
    (Get-DeliveryRecoveryConfig).recoveryEnabled -eq $true
}

Invoke-Test "03 retry enabled" {
    (Get-DeliveryRecoveryConfig).retryEnabled -eq $true
}

Invoke-Test "04 max retries configured" {
    (Get-DeliveryRecoveryConfig).maxRetries -eq 3
}

Invoke-Test "05 initialization succeeds" {
    $R = Initialize-DeliveryRecovery `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "READY")
}

Invoke-Test "06 initial retry count zero" {
    (Get-DeliveryRecoveryRecord -DeliveryId "DELIVERY-7H65-001").RetryCount -eq 0
}

Invoke-Test "07 failure registration succeeds" {
    $R = Register-DeliveryFailure `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "FAILED")
}

Invoke-Test "08 failed state persisted" {
    (Get-DeliveryRecoveryRecord -DeliveryId "DELIVERY-7H65-001").RecoveryState -eq "FAILED"
}

Invoke-Test "09 first retry authorized" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "AUTHORIZED") -and
    ($R.RetryCount -eq 1)
}

Invoke-Test "10 retry count persisted" {
    (Get-DeliveryRecoveryRecord -DeliveryId "DELIVERY-7H65-001").RetryCount -eq 1
}

Invoke-Test "11 retry requires failed state" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "RETRY_REQUIRES_FAILED_STATE")
}

Invoke-Test "12 second failure can be registered" {
    $R = Register-DeliveryFailure `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "FAILED")
}

Invoke-Test "13 second retry authorized" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "AUTHORIZED") -and
    ($R.RetryCount -eq 2)
}

Invoke-Test "14 third failure registered" {
    $R = Register-DeliveryFailure `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true)
}

Invoke-Test "15 third retry authorized" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.RetryCount -eq 3)
}

Invoke-Test "16 fourth retry blocked" {
    $R = Register-DeliveryFailure `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    $R2 = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R2.Success -eq $false) -and
    ($R2.Status -eq "BLOCKED") -and
    ($R2.Reason -eq "MAX_RETRIES_REACHED")
}

Invoke-Test "17 execution mismatch blocked" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-OTHER" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "18 tenant mismatch blocked" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-OTHER" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "19 client mismatch blocked" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-OTHER" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "20 project mismatch blocked" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-7H65-001" `
        -ExecutionId "EXEC-7H65-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-OTHER"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "21 missing delivery blocked" {
    $R = Request-DeliveryRetry `
        -DeliveryId "" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "22 unknown delivery blocked" {
    $R = Request-DeliveryRetry `
        -DeliveryId "DELIVERY-UNKNOWN" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "RECOVERY_NOT_INITIALIZED")
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryRecoveryConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryRecoveryConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-65 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"