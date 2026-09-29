Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-result-provenance"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Result-Provenance.ps1"
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
    -ExecutionId "EXEC-7H58-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -WorkerId "MAYA"

$Result = [pscustomobject][ordered]@{
    Success     = $true
    Status      = "CLEAN"
    ExecutionId = "EXEC-7H58-001"
    TenantId    = "TENANT-001"
    ClientId    = "CLIENT-001"
    ProjectId   = "PROJECT-001"
    WorkerId    = "MAYA"
    Output      = "Bonjour Kader"
    Redacted    = $false
    Findings    = 0
    Reason      = "NO_SENSITIVE_DATA"
}

Invoke-Test "01 config enabled" {
    (Get-ExecutionResultProvenanceConfig).enabled -eq $true
}

Invoke-Test "02 provenance enabled" {
    (Get-ExecutionResultProvenanceConfig).provenanceEnabled -eq $true
}

Invoke-Test "03 correlation enabled" {
    (Get-ExecutionResultProvenanceConfig).correlationEnabled -eq $true
}

Invoke-Test "04 correlation id generated" {
    -not [string]::IsNullOrWhiteSpace($Correlation.CorrelationId)
}

Invoke-Test "05 execution provenance valid" {
    (Test-ExecutionResultProvenance -Result $Result -Correlation $Correlation).Valid -eq $true
}

Invoke-Test "06 execution id matched" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).ExecutionId -eq "EXEC-7H58-001"
}

Invoke-Test "07 tenant matched" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).TenantId -eq "TENANT-001"
}

Invoke-Test "08 client matched" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).ClientId -eq "CLIENT-001"
}

Invoke-Test "09 project matched" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).ProjectId -eq "PROJECT-001"
}

Invoke-Test "10 worker matched" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).WorkerId -eq "MAYA"
}

Invoke-Test "11 correlation preserved" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).CorrelationId -eq $Correlation.CorrelationId
}

Invoke-Test "12 output preserved" {
    (Protect-ExecutionResultProvenance -Result $Result -Correlation $Correlation).Output -eq "Bonjour Kader"
}

Invoke-Test "13 execution mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.ExecutionId = "EXEC-OTHER"

    $Check = Test-ExecutionResultProvenance -Result $Result -Correlation $Bad

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "EXECUTION_ID_MISMATCH")
}

Invoke-Test "14 tenant mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.TenantId = "TENANT-OTHER"

    $Check = Test-ExecutionResultProvenance -Result $Result -Correlation $Bad

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "TENANT_MISMATCH")
}

Invoke-Test "15 client mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.ClientId = "CLIENT-OTHER"

    $Check = Test-ExecutionResultProvenance -Result $Result -Correlation $Bad

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "CLIENT_MISMATCH")
}

Invoke-Test "16 project mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.ProjectId = "PROJECT-OTHER"

    $Check = Test-ExecutionResultProvenance -Result $Result -Correlation $Bad

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "PROJECT_MISMATCH")
}

Invoke-Test "17 worker mismatch blocked" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.WorkerId = "WORKER-OTHER"

    $Check = Test-ExecutionResultProvenance -Result $Result -Correlation $Bad

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "WORKER_MISMATCH")
}

Invoke-Test "18 null result blocked" {
    $Check = Test-ExecutionResultProvenance -Result $null -Correlation $Correlation

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "RESULT_NULL")
}

Invoke-Test "19 null correlation blocked" {
    $Check = Test-ExecutionResultProvenance -Result $Result -Correlation $null

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "CORRELATION_NULL")
}

Invoke-Test "20 missing execution id blocked" {
    $Bad = $Result.PSObject.Copy()
    $Bad.ExecutionId = ""

    $Check = Test-ExecutionResultProvenance -Result $Bad -Correlation $Correlation

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "EXECUTION_ID_MISSING")
}

Invoke-Test "21 missing tenant blocked" {
    $Bad = $Result.PSObject.Copy()
    $Bad.TenantId = ""

    $Check = Test-ExecutionResultProvenance -Result $Bad -Correlation $Correlation

    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "TENANT_ID_MISSING")
}

Invoke-Test "22 blocked result contains no raw output" {
    $Bad = $Correlation.PSObject.Copy()
    $Bad.TenantId = "TENANT-OTHER"

    $Protected = Protect-ExecutionResultProvenance `
        -Result $Result `
        -Correlation $Bad

    ($Protected.Status -eq "BLOCKED") -and
    ($Protected.Output -eq "")
}

Invoke-Test "23 no secrets or payload capture" {
    $Config = Get-ExecutionResultProvenanceConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-ExecutionResultProvenanceConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-58 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"