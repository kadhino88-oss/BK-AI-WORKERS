Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-result-delivery"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Result-Delivery.ps1"
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

$CorrelationId = "CORR-7H60-001"

$Result = [pscustomobject][ordered]@{
    Success       = $true
    Finalized     = $true
    Status        = "FINAL"
    CorrelationId = $CorrelationId
    ExecutionId   = "EXEC-7H60-001"
    TenantId      = "TENANT-001"
    ClientId      = "CLIENT-001"
    ProjectId     = "PROJECT-001"
    WorkerId      = "MAYA"
    Output        = "Execution completed successfully."
    Redacted      = $false
    Findings      = 0
    Reason        = "EXECUTION_RESULT_FINALIZED"
}

$Target = New-ExecutionResultDeliveryTarget `
    -ExecutionId "EXEC-7H60-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -WorkerId "MAYA" `
    -TargetId "INTERNAL-TARGET-001" `
    -Channel "INTERNAL"

Invoke-Test "01 config enabled" {
    (Get-ExecutionResultDeliveryConfig).enabled -eq $true
}

Invoke-Test "02 delivery guard enabled" {
    (Get-ExecutionResultDeliveryConfig).deliveryGuardEnabled -eq $true
}

Invoke-Test "03 finalized result required" {
    (Get-ExecutionResultDeliveryConfig).requireFinalizedResult -eq $true
}

Invoke-Test "04 valid delivery accepted" {
    (Test-ExecutionResultDelivery -Result $Result -Target $Target).Valid -eq $true
}

Invoke-Test "05 delivery authorized" {
    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Target
    ($R.Success -eq $true) -and
    ($R.Status -eq "AUTHORIZED")
}

Invoke-Test "06 delivery id generated" {
    -not [string]::IsNullOrWhiteSpace(
        (Protect-ExecutionResultDelivery -Result $Result -Target $Target).DeliveryId
    )
}

Invoke-Test "07 execution preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).ExecutionId -eq "EXEC-7H60-001"
}

Invoke-Test "08 tenant preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).TenantId -eq "TENANT-001"
}

Invoke-Test "09 client preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).ClientId -eq "CLIENT-001"
}

Invoke-Test "10 project preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).ProjectId -eq "PROJECT-001"
}

Invoke-Test "11 worker preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).WorkerId -eq "MAYA"
}

Invoke-Test "12 target preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).TargetId -eq "INTERNAL-TARGET-001"
}

Invoke-Test "13 channel preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).Channel -eq "INTERNAL"
}

Invoke-Test "14 correlation preserved" {
    (Protect-ExecutionResultDelivery -Result $Result -Target $Target).CorrelationId -eq $CorrelationId
}

Invoke-Test "15 non-final result blocked" {
    $Bad = $Result.PSObject.Copy()
    $Bad.Finalized = $false
    $Bad.Status = "CLEAN"

    $R = Protect-ExecutionResultDelivery -Result $Bad -Target $Target

    ($R.Success -eq $false) -and
    ($R.Status -eq "BLOCKED")
}

Invoke-Test "16 execution mismatch blocked" {
    $Bad = $Target.PSObject.Copy()
    $Bad.ExecutionId = "EXEC-OTHER"

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Success -eq $false) -and
    ($R.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "17 tenant mismatch blocked" {
    $Bad = $Target.PSObject.Copy()
    $Bad.TenantId = "TENANT-OTHER"

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "18 client mismatch blocked" {
    $Bad = $Target.PSObject.Copy()
    $Bad.ClientId = "CLIENT-OTHER"

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Success -eq $false) -and
    ($R.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "19 project mismatch blocked" {
    $Bad = $Target.PSObject.Copy()
    $Bad.ProjectId = "PROJECT-OTHER"

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Success -eq $false) -and
    ($R.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "20 target missing blocked" {
    $Bad = $Target.PSObject.Copy()
    $Bad.TargetId = ""

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Success -eq $false) -and
    ($R.Reason -eq "TARGET_ID_MISSING")
}

Invoke-Test "21 invalid channel blocked" {
    $Bad = $Target.PSObject.Copy()
    $Bad.Channel = "UNKNOWN_CHANNEL"

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Success -eq $false) -and
    ($R.Reason -eq "CHANNEL_INVALID")
}

Invoke-Test "22 blocked output empty" {
    $Bad = $Target.PSObject.Copy()
    $Bad.TenantId = "TENANT-OTHER"

    $R = Protect-ExecutionResultDelivery -Result $Result -Target $Bad

    ($R.Status -eq "BLOCKED") -and
    ($R.Output -eq "")
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-ExecutionResultDeliveryConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-ExecutionResultDeliveryConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-60 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"