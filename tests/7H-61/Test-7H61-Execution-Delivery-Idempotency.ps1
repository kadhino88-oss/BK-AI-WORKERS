Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-idempotency"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-Idempotency.ps1"
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

Reset-DeliveryIdempotency

$Base = @{
    DeliveryId = "DELIVERY-7H61-001"
    ExecutionId = "EXEC-7H61-001"
    TenantId = "TENANT-001"
    ClientId = "CLIENT-001"
    ProjectId = "PROJECT-001"
    TargetId = "TARGET-001"
    Channel = "INTERNAL"
}

Invoke-Test "01 config enabled" {
    (Get-DeliveryIdempotencyConfig).enabled -eq $true
}

Invoke-Test "02 idempotency enabled" {
    (Get-DeliveryIdempotencyConfig).idempotencyEnabled -eq $true
}

Invoke-Test "03 duplicate detection enabled" {
    (Get-DeliveryIdempotencyConfig).duplicateDetectionEnabled -eq $true
}

Invoke-Test "04 empty state initially" {
    @(Get-DeliveryIdempotencyState).Count -eq 0
}

Invoke-Test "05 first registration allowed" {
    $R = Register-DeliveryAttempt @Base
    ($R.Success -eq $true) -and
    ($R.Status -eq "REGISTERED")
}

Invoke-Test "06 state contains one record" {
    @(Get-DeliveryIdempotencyState).Count -eq 1
}

Invoke-Test "07 duplicate detected" {
    $R = Register-DeliveryAttempt @Base
    ($R.Success -eq $true) -and
    ($R.Status -eq "DUPLICATE")
}

Invoke-Test "08 duplicate does not create record" {
    @(Get-DeliveryIdempotencyState).Count -eq 1
}

Invoke-Test "09 same execution different target allowed" {
    $R = Register-DeliveryAttempt `
        -DeliveryId "DELIVERY-7H61-002" `
        -ExecutionId $Base.ExecutionId `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId "TARGET-002" `
        -Channel "INTERNAL"

    ($R.Success -eq $true) -and
    ($R.Status -eq "REGISTERED")
}

Invoke-Test "10 different execution allowed" {
    $R = Register-DeliveryAttempt `
        -DeliveryId "DELIVERY-7H61-001" `
        -ExecutionId "EXEC-OTHER" `
        -TenantId $Base.TenantId `
        -ClientId $Base.ClientId `
        -ProjectId $Base.ProjectId `
        -TargetId $Base.TargetId `
        -Channel "INTERNAL"

    ($R.Success -eq $true) -and
    ($R.Status -eq "REGISTERED")
}

Invoke-Test "11 tenant preserved" {
    $Records = @(Get-DeliveryIdempotencyState)
    $Record = @(
        $Records |
        Where-Object {
            $_.DeliveryId -eq "DELIVERY-7H61-001"
        }
    ) | Select-Object -First 1

    $Record.TenantId -eq "TENANT-001"
}

Invoke-Test "12 client preserved" {
    $Records = @(Get-DeliveryIdempotencyState)
    $Record = @(
        $Records |
        Where-Object {
            $_.DeliveryId -eq "DELIVERY-7H61-001"
        }
    ) | Select-Object -First 1

    $Record.ClientId -eq "CLIENT-001"
}

Invoke-Test "13 project preserved" {
    $Records = @(Get-DeliveryIdempotencyState)
    $Record = @(
        $Records |
        Where-Object {
            $_.DeliveryId -eq "DELIVERY-7H61-001"
        }
    ) | Select-Object -First 1

    $Record.ProjectId -eq "PROJECT-001"
}

Invoke-Test "14 target preserved" {
    $Records = @(Get-DeliveryIdempotencyState)
    $Record = @(
        $Records |
        Where-Object {
            $_.DeliveryId -eq "DELIVERY-7H61-001"
        }
    ) | Select-Object -First 1

    $Record.TargetId -eq "TARGET-001"
}

Invoke-Test "15 channel preserved" {
    $Records = @(Get-DeliveryIdempotencyState)
    $Record = @(
        $Records |
        Where-Object {
            $_.DeliveryId -eq "DELIVERY-7H61-001"
        }
    ) | Select-Object -First 1

    $Record.Channel -eq "INTERNAL"
}

Invoke-Test "16 delivery id missing blocked" {
    $R = Register-DeliveryAttempt `
        -DeliveryId "" `
        -ExecutionId "EXEC-X" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -TargetId "TARGET-X" `
        -Channel "INTERNAL"

    ($R.Success -eq $false) -and
    ($R.Status -eq "BLOCKED") -and
    ($R.Reason -eq "DELIVERY_ID_MISSING")
}

Invoke-Test "17 execution id missing blocked" {
    $R = Register-DeliveryAttempt `
        -DeliveryId "DELIVERY-X" `
        -ExecutionId "" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -TargetId "TARGET-X" `
        -Channel "INTERNAL"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISSING")
}

Invoke-Test "18 target id missing blocked" {
    $R = Register-DeliveryAttempt `
        -DeliveryId "DELIVERY-X2" `
        -ExecutionId "EXEC-X2" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -TargetId "" `
        -Channel "INTERNAL"

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TARGET_ID_MISSING")
}

Invoke-Test "19 idempotency key deterministic" {
    $A = Get-DeliveryIdempotencyKey `
        -DeliveryId "D1" `
        -ExecutionId "E1" `
        -TargetId "T1"

    $B = Get-DeliveryIdempotencyKey `
        -DeliveryId "D1" `
        -ExecutionId "E1" `
        -TargetId "T1"

    $A -eq $B
}

Invoke-Test "20 different key for different target" {
    $A = Get-DeliveryIdempotencyKey `
        -DeliveryId "D1" `
        -ExecutionId "E1" `
        -TargetId "T1"

    $B = Get-DeliveryIdempotencyKey `
        -DeliveryId "D1" `
        -ExecutionId "E1" `
        -TargetId "T2"

    $A -ne $B
}

Invoke-Test "21 state persists after reload" {
    $RecordsBefore = @(Get-DeliveryIdempotencyState)

    $Raw = Get-Content -Raw `
        "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-idempotency\state\delivery-records.json"

    $RecordsAfter = @(Get-DeliveryIdempotencyState)

    ($Raw.Length -gt 0) -and
    ($RecordsAfter.Count -eq $RecordsBefore.Count)
}

Invoke-Test "22 config captures no secrets" {
    $Text = Get-Content -Raw $ConfigFile

    ($Text -notmatch "(?i)password\s*[:=]") -and
    ($Text -notmatch "(?i)api[_-]?key\s*[:=]") -and
    ($Text -notmatch "(?i)secret\s*[:=]")
}

Invoke-Test "23 config captures no payloads" {
    $Config = Get-DeliveryIdempotencyConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryIdempotencyConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-61 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"