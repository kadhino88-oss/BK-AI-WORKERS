Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-expiration"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Expiration.ps1"
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

Reset-DeliveryExpiration

$ExpiredAt = [DateTime]::UtcNow.AddSeconds(-60).ToString("o")

Invoke-Test "01 config enabled" {
    (Get-DeliveryExpirationConfig).enabled -eq $true
}

Invoke-Test "02 expiration guard enabled" {
    (Get-DeliveryExpirationConfig).expirationGuardEnabled -eq $true
}

Invoke-Test "03 require lease id" {
    (Get-DeliveryExpirationConfig).requireLeaseId -eq $true
}

Invoke-Test "04 expired timestamp accepted" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-7H67-001" `
        -DeliveryId "DELIVERY-7H67-001" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $ExpiredAt

    ($R.Success -eq $true) -and
    ($R.Status -eq "EXPIRED")
}

Invoke-Test "05 expiration persisted" {
    @(Get-DeliveryExpirationState).Count -eq 1
}

$Record = Get-DeliveryExpirationState | Select-Object -First 1

Invoke-Test "06 expiration record valid" {
    (Test-DeliveryExpiration `
        -Record $Record `
        -LeaseId "LEASE-7H67-001" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001").Valid -eq $true
}

Invoke-Test "07 duplicate expiration detected" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-7H67-001" `
        -DeliveryId "DELIVERY-7H67-001" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $ExpiredAt

    ($R.Success -eq $true) -and
    ($R.Status -eq "DUPLICATE")
}

Invoke-Test "08 duplicate does not create record" {
    @(Get-DeliveryExpirationState).Count -eq 1
}

Invoke-Test "09 future expiration remains active" {
    $Future = [DateTime]::UtcNow.AddSeconds(300).ToString("o")

    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-FUTURE" `
        -DeliveryId "DELIVERY-FUTURE" `
        -ExecutionId "EXEC-FUTURE" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $Future

    ($R.Success -eq $false) -and
    ($R.Status -eq "ACTIVE") -and
    ($R.Reason -eq "LEASE_NOT_EXPIRED")
}

Invoke-Test "10 lease id mismatch blocked" {
    $R = Test-DeliveryExpiration `
        -Record $Record `
        -LeaseId "LEASE-OTHER" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "LEASE_ID_MISMATCH")
}

Invoke-Test "11 execution mismatch blocked" {
    $R = Test-DeliveryExpiration `
        -Record $Record `
        -LeaseId "LEASE-7H67-001" `
        -ExecutionId "EXEC-OTHER" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "12 tenant mismatch blocked" {
    $R = Test-DeliveryExpiration `
        -Record $Record `
        -LeaseId "LEASE-7H67-001" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-OTHER" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "13 client mismatch blocked" {
    $R = Test-DeliveryExpiration `
        -Record $Record `
        -LeaseId "LEASE-7H67-001" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-OTHER" `
        -ProjectId "PROJECT-001"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "14 project mismatch blocked" {
    $R = Test-DeliveryExpiration `
        -Record $Record `
        -LeaseId "LEASE-7H67-001" `
        -ExecutionId "EXEC-7H67-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-OTHER"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "15 lease id missing blocked" {
    $R = Register-DeliveryExpiration `
        -LeaseId "" `
        -DeliveryId "DELIVERY-X" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $ExpiredAt

    ($R.Success -eq $false) -and
    ($R.Reason -eq "LEASE_ID_MISSING")
}

Invoke-Test "16 delivery id missing blocked" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-X" `
        -DeliveryId "" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $ExpiredAt

    ($R.Success -eq $false) -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "17 execution id missing blocked" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-X2" `
        -DeliveryId "DELIVERY-X2" `
        -ExecutionId "" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $ExpiredAt

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISSING")
}

Invoke-Test "18 tenant missing blocked" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-X3" `
        -DeliveryId "DELIVERY-X3" `
        -ExecutionId "EXEC-X3" `
        -TenantId "" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc $ExpiredAt

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TENANT_ID_MISSING")
}

Invoke-Test "19 expiration missing blocked" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-X4" `
        -DeliveryId "DELIVERY-X4" `
        -ExecutionId "EXEC-X4" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc ""

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXPIRATION_MISSING")
}

Invoke-Test "20 expiration invalid blocked" {
    $R = Register-DeliveryExpiration `
        -LeaseId "LEASE-X5" `
        -DeliveryId "DELIVERY-X5" `
        -ExecutionId "EXEC-X5" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -ExpiresAtUtc "NOT-A-DATE"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXPIRATION_INVALID")
}

Invoke-Test "21 null expiration record invalid" {
    $R = Test-DeliveryExpiration `
        -Record $null `
        -LeaseId "LEASE-X" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Valid -eq $false) -and
    ($R.Reason -eq "EXPIRATION_RECORD_NULL")
}

Invoke-Test "22 expired status persisted" {
    $Record.Status -eq "EXPIRED"
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryExpirationConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryExpirationConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-67 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"