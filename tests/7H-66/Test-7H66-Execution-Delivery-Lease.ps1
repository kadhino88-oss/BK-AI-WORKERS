Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-lease"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Lease.ps1"
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

Reset-DeliveryLeases

Invoke-Test "01 config enabled" {
    (Get-DeliveryLeaseConfig).enabled -eq $true
}

Invoke-Test "02 lease guard enabled" {
    (Get-DeliveryLeaseConfig).leaseGuardEnabled -eq $true
}

Invoke-Test "03 renewal enabled" {
    (Get-DeliveryLeaseConfig).renewalEnabled -eq $true
}

Invoke-Test "04 lease duration configured" {
    (Get-DeliveryLeaseConfig).leaseDurationSeconds -eq 300
}

Invoke-Test "05 first lease acquired" {
    $R = Acquire-DeliveryLease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "ACTIVE")
}

$Lease = Get-DeliveryLease `
    -LeaseId (
        @(
            Get-DeliveryLeaseState |
            Where-Object {
                $_.DeliveryId -eq "DELIVERY-7H66-001"
            }
        ) |
        Select-Object -First 1
    ).LeaseId

Invoke-Test "06 lease persisted" {
    @(
        Get-DeliveryLeaseState |
        Where-Object {
            $_.DeliveryId -eq "DELIVERY-7H66-001"
        }
    ).Count -eq 1
}

Invoke-Test "07 lease valid" {
    $Check = Test-DeliveryLease `
        -Lease $Lease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($Check.Valid -eq $true) -and
    ($Check.Status -eq "ACTIVE")
}

Invoke-Test "08 duplicate active lease blocked" {
    $R = Acquire-DeliveryLease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "ACTIVE_LEASE_EXISTS")
}

Invoke-Test "09 execution mismatch blocked" {
    $Check = Test-DeliveryLease `
        -Lease $Lease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-OTHER" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "10 tenant mismatch blocked" {
    $Check = Test-DeliveryLease `
        -Lease $Lease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-OTHER" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "11 client mismatch blocked" {
    $Check = Test-DeliveryLease `
        -Lease $Lease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-OTHER" `
        -ProjectId "PROJECT-001"

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "12 project mismatch blocked" {
    $Check = Test-DeliveryLease `
        -Lease $Lease `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-OTHER"

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "13 first renewal succeeds" {
    $R = Renew-DeliveryLease `
        -LeaseId $Lease.LeaseId `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001"

    ($R.Success -eq $true) -and
    ($R.RenewalCount -eq 1)
}

Invoke-Test "14 renewal count persisted" {
    (Get-DeliveryLease -LeaseId $Lease.LeaseId).RenewalCount -eq 1
}

Invoke-Test "15 renewal mismatch blocked" {
    $R = Renew-DeliveryLease `
        -LeaseId $Lease.LeaseId `
        -ExecutionId "EXEC-OTHER" `
        -TenantId "TENANT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "16 second renewal succeeds" {
    $R = Renew-DeliveryLease `
        -LeaseId $Lease.LeaseId `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001"

    ($R.Success -eq $true) -and
    ($R.RenewalCount -eq 2)
}

Invoke-Test "17 third renewal succeeds" {
    $R = Renew-DeliveryLease `
        -LeaseId $Lease.LeaseId `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001"

    ($R.Success -eq $true) -and
    ($R.RenewalCount -eq 3)
}

Invoke-Test "18 fourth renewal blocked" {
    $R = Renew-DeliveryLease `
        -LeaseId $Lease.LeaseId `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "MAX_RENEWALS_REACHED")
}

Invoke-Test "19 release succeeds" {
    $R = Release-DeliveryLease `
        -LeaseId $Lease.LeaseId `
        -ExecutionId "EXEC-7H66-001"

    ($R.Success -eq $true) -and
    ($R.Status -eq "RELEASED")
}

Invoke-Test "20 released lease invalid" {
    $Check = Test-DeliveryLease `
        -Lease (Get-DeliveryLease -LeaseId $Lease.LeaseId) `
        -DeliveryId "DELIVERY-7H66-001" `
        -ExecutionId "EXEC-7H66-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "LEASE_NOT_ACTIVE")
}

Invoke-Test "21 unknown lease blocked" {
    $R = Renew-DeliveryLease `
        -LeaseId "UNKNOWN-LEASE" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "LEASE_NOT_FOUND")
}

Invoke-Test "22 missing delivery blocked" {
    $R = Acquire-DeliveryLease `
        -DeliveryId "" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryLeaseConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryLeaseConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-66 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"