Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-state"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Delivery-State.ps1"
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

Reset-DeliveryState

Invoke-Test "01 config enabled" {
    (Get-DeliveryStateConfig).enabled -eq $true
}

Invoke-Test "02 state machine enabled" {
    (Get-DeliveryStateConfig).stateMachineEnabled -eq $true
}

Invoke-Test "03 transition guard enabled" {
    (Get-DeliveryStateConfig).transitionGuardEnabled -eq $true
}

Invoke-Test "04 valid state list" {
    @(Get-DeliveryStates).Count -eq 6
}

Invoke-Test "05 initialization succeeds" {
    $R = Initialize-DeliveryState `
        -DeliveryId "DELIVERY-7H62-001" `
        -ExecutionId "EXEC-7H62-001" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -WorkerId "MAYA"

    ($R.Success -eq $true) -and
    ($R.Status -eq "REGISTERED")
}

Invoke-Test "06 initial state registered" {
    (Get-DeliveryCurrentState -DeliveryId "DELIVERY-7H62-001").State -eq "REGISTERED"
}

Invoke-Test "07 registered to authorized allowed" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "REGISTERED" `
        -ToState "AUTHORIZED").Allowed -eq $true
}

Invoke-Test "08 authorized transition succeeds" {
    $R = Set-DeliveryState `
        -DeliveryId "DELIVERY-7H62-001" `
        -ToState "AUTHORIZED"

    ($R.Success -eq $true) -and
    ($R.Status -eq "AUTHORIZED")
}

Invoke-Test "09 authorized to delivering allowed" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "AUTHORIZED" `
        -ToState "DELIVERING").Allowed -eq $true
}

Invoke-Test "10 delivering transition succeeds" {
    (Set-DeliveryState `
        -DeliveryId "DELIVERY-7H62-001" `
        -ToState "DELIVERING").Success -eq $true
}

Invoke-Test "11 delivering to delivered allowed" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "DELIVERING" `
        -ToState "DELIVERED").Allowed -eq $true
}

Invoke-Test "12 delivered transition succeeds" {
    (Set-DeliveryState `
        -DeliveryId "DELIVERY-7H62-001" `
        -ToState "DELIVERED").Success -eq $true
}

Invoke-Test "13 delivered is terminal" {
    $R = Set-DeliveryState `
        -DeliveryId "DELIVERY-7H62-001" `
        -ToState "AUTHORIZED"

    ($R.Success -eq $false) -and
    ($R.Status -eq "BLOCKED")
}

Invoke-Test "14 invalid transition blocked" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "REGISTERED" `
        -ToState "DELIVERED").Allowed -eq $false
}

Invoke-Test "15 blocked to delivered denied" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "BLOCKED" `
        -ToState "DELIVERED").Allowed -eq $false
}

Invoke-Test "16 failed retry path allowed" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "FAILED" `
        -ToState "AUTHORIZED").Allowed -eq $true
}

Invoke-Test "17 failed to delivering denied" {
    (Test-DeliveryTransition `
        -DeliveryId "DELIVERY-7H62-001" `
        -FromState "FAILED" `
        -ToState "DELIVERING").Allowed -eq $false
}

Invoke-Test "18 missing delivery id blocked" {
    $R = Set-DeliveryState `
        -DeliveryId "" `
        -ToState "AUTHORIZED"

    ($R.Success -eq $false) -and
    ($R.Status -eq "BLOCKED")
}

Invoke-Test "19 unknown from state blocked" {
    $R = Test-DeliveryTransition `
        -DeliveryId "D1" `
        -FromState "UNKNOWN" `
        -ToState "AUTHORIZED"

    ($R.Allowed -eq $false) -and
    ($R.Reason -eq "FROM_STATE_INVALID")
}

Invoke-Test "20 unknown to state blocked" {
    $R = Test-DeliveryTransition `
        -DeliveryId "D1" `
        -FromState "REGISTERED" `
        -ToState "UNKNOWN"

    ($R.Allowed -eq $false) -and
    ($R.Reason -eq "TO_STATE_INVALID")
}

Invoke-Test "21 persistence contains correct context" {
    $R = Get-DeliveryCurrentState -DeliveryId "DELIVERY-7H62-001"

    ($R.ExecutionId -eq "EXEC-7H62-001") -and
    ($R.TenantId -eq "TENANT-001") -and
    ($R.ClientId -eq "CLIENT-001") -and
    ($R.ProjectId -eq "PROJECT-001") -and
    ($R.WorkerId -eq "MAYA")
}

Invoke-Test "22 transition count persisted" {
    (Get-DeliveryCurrentState -DeliveryId "DELIVERY-7H62-001").TransitionCount -eq 3
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-DeliveryStateConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-DeliveryStateConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-62 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"