Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-result-finalization"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Result-Finalization.ps1"
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

$Correlation = New-ExecutionResultCorrelation `
    -ExecutionId "EXEC-7H59-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -WorkerId "MAYA"

$Valid = [pscustomobject][ordered]@{
    Success     = $true
    Status      = "CLEAN"
    ExecutionId = "EXEC-7H59-001"
    TenantId    = "TENANT-001"
    ClientId    = "CLIENT-001"
    ProjectId   = "PROJECT-001"
    WorkerId    = "MAYA"
    Output      = "Execution completed successfully."
    Redacted    = $false
    Findings    = 0
    Reason      = "NO_SENSITIVE_DATA"
}

Invoke-Test "01 config enabled" {
    (Get-ExecutionResultFinalizationConfig).enabled -eq $true
}

Invoke-Test "02 finalization enabled" {
    (Get-ExecutionResultFinalizationConfig).finalizationEnabled -eq $true
}

Invoke-Test "03 contract validation required" {
    (Get-ExecutionResultFinalizationConfig).requireContractValidation -eq $true
}

Invoke-Test "04 provenance validation required" {
    (Get-ExecutionResultFinalizationConfig).requireProvenanceValidation -eq $true
}

Invoke-Test "05 valid result finalized" {
    $R = Finalize-ExecutionResult -Result $Valid -Correlation $Correlation
    ($R.Finalized -eq $true) -and ($R.Status -eq "FINAL")
}

Invoke-Test "06 success preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).Success -eq $true
}

Invoke-Test "07 correlation preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).CorrelationId -eq $Correlation.CorrelationId
}

Invoke-Test "08 execution preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).ExecutionId -eq "EXEC-7H59-001"
}

Invoke-Test "09 tenant preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).TenantId -eq "TENANT-001"
}

Invoke-Test "10 client preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).ClientId -eq "CLIENT-001"
}

Invoke-Test "11 project preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).ProjectId -eq "PROJECT-001"
}

Invoke-Test "12 worker preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).WorkerId -eq "MAYA"
}

Invoke-Test "13 output preserved" {
    (Finalize-ExecutionResult -Result $Valid -Correlation $Correlation).Output -eq "Execution completed successfully."
}

Invoke-Test "14 null result blocked" {
    $R = Finalize-ExecutionResult -Result $null -Correlation $Correlation
    ($R.Finalized -eq $false) -and
    ($R.Status -eq "BLOCKED") -and
    ($R.Reason -eq "RESULT_NULL")
}

Invoke-Test "15 null correlation blocked" {
    $R = Finalize-ExecutionResult -Result $Valid -Correlation $null
    ($R.Finalized -eq $false) -and
    ($R.Reason -eq "CORRELATION_NULL")
}

Invoke-Test "16 execution mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.ExecutionId = "EXEC-OTHER"

    $R = Finalize-ExecutionResult -Result $Valid -Correlation $Bad

    ($R.Finalized -eq $false) -and
    ($R.Reason -match "EXECUTION_ID_MISMATCH")
}

Invoke-Test "17 tenant mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.TenantId = "TENANT-OTHER"

    $R = Finalize-ExecutionResult -Result $Valid -Correlation $Bad

    ($R.Finalized -eq $false) -and
    ($R.Reason -match "TENANT_MISMATCH")
}

Invoke-Test "18 project mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.ProjectId = "PROJECT-OTHER"

    $R = Finalize-ExecutionResult -Result $Valid -Correlation $Bad

    ($R.Finalized -eq $false) -and
    ($R.Reason -match "PROJECT_MISMATCH")
}

Invoke-Test "19 invalid status blocked" {
    $Bad = $Valid.PSObject.Copy()
    $Bad.Status = "INVALID_STATUS"

    $R = Finalize-ExecutionResult -Result $Bad -Correlation $Correlation

    ($R.Finalized -eq $false) -and
    ($R.Reason -match "STATUS_INVALID")
}

Invoke-Test "20 missing execution blocked" {
    $Bad = $Valid.PSObject.Copy()
    $Bad.ExecutionId = ""

    $R = Finalize-ExecutionResult -Result $Bad -Correlation $Correlation

    ($R.Finalized -eq $false) -and
    ($R.Reason -match "EXECUTION_ID_MISSING")
}

Invoke-Test "21 blocked result cannot finalize" {
    $Blocked = $Valid.PSObject.Copy()
    $Blocked.Status = "BLOCKED"
    $Blocked.Success = $false

    $R = Finalize-ExecutionResult -Result $Blocked -Correlation $Correlation

    ($R.Finalized -eq $false) -and
    ($R.Reason -eq "BLOCKED_RESULT_CANNOT_FINALIZE")
}

Invoke-Test "22 finalization output is single object" {
    $R = Finalize-ExecutionResult -Result $Valid -Correlation $Correlation
    @($R).Count -eq 1
}

Invoke-Test "23 no secret or payload capture" {
    $Config = Get-ExecutionResultFinalizationConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-ExecutionResultFinalizationConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-59 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"