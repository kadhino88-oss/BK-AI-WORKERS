Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-result-contract"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Result-Contract.ps1"
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

$Valid = New-ExecutionResultEnvelope `
    -Success $true `
    -Status "CLEAN" `
    -ExecutionId "EXEC-7H57-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -WorkerId "MAYA" `
    -Output "Bonjour Kader" `
    -Redacted $false `
    -Findings 0 `
    -Reason "NO_SENSITIVE_DATA"

Invoke-Test "01 config enabled" {
    (Get-ExecutionResultContractConfig).enabled -eq $true
}

Invoke-Test "02 contract validation enabled" {
    (Get-ExecutionResultContractConfig).contractValidationEnabled -eq $true
}

Invoke-Test "03 live execution disabled" {
    (Get-ExecutionResultContractConfig).liveExecutionEnabled -eq $false
}

Invoke-Test "04 valid envelope accepted" {
    (Test-ExecutionResultEnvelope $Valid).Valid -eq $true
}

Invoke-Test "05 success field preserved" {
    (Protect-ExecutionResultEnvelope $Valid).Success -eq $true
}

Invoke-Test "06 status preserved" {
    (Protect-ExecutionResultEnvelope $Valid).Status -eq "CLEAN"
}

Invoke-Test "07 execution id preserved" {
    (Protect-ExecutionResultEnvelope $Valid).ExecutionId -eq "EXEC-7H57-001"
}

Invoke-Test "08 tenant preserved" {
    (Protect-ExecutionResultEnvelope $Valid).TenantId -eq "TENANT-001"
}

Invoke-Test "09 client preserved" {
    (Protect-ExecutionResultEnvelope $Valid).ClientId -eq "CLIENT-001"
}

Invoke-Test "10 project preserved" {
    (Protect-ExecutionResultEnvelope $Valid).ProjectId -eq "PROJECT-001"
}

Invoke-Test "11 worker preserved" {
    (Protect-ExecutionResultEnvelope $Valid).WorkerId -eq "MAYA"
}

Invoke-Test "12 output preserved" {
    (Protect-ExecutionResultEnvelope $Valid).Output -eq "Bonjour Kader"
}

Invoke-Test "13 redacted flag preserved" {
    (Protect-ExecutionResultEnvelope $Valid).Redacted -eq $false
}

Invoke-Test "14 findings preserved" {
    (Protect-ExecutionResultEnvelope $Valid).Findings -eq 0
}

Invoke-Test "15 reason preserved" {
    (Protect-ExecutionResultEnvelope $Valid).Reason -eq "NO_SENSITIVE_DATA"
}

Invoke-Test "16 null result blocked" {
    $Result = Protect-ExecutionResultEnvelope $null
    ($Result.Success -eq $false) -and
    ($Result.Status -eq "BLOCKED") -and
    ($Result.Reason -eq "RESULT_NULL")
}

Invoke-Test "17 missing execution blocked" {
    $Bad = New-ExecutionResultEnvelope `
        -Success $true `
        -Status "CLEAN" `
        -ExecutionId "" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -WorkerId "MAYA" `
        -Output "ok" `
        -Redacted $false `
        -Findings 0 `
        -Reason "NO_SENSITIVE_DATA"

    $Check = Test-ExecutionResultEnvelope $Bad
    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "EXECUTION_ID_MISSING")
}

Invoke-Test "18 missing tenant blocked" {
    $Bad = $Valid.PSObject.Copy()
    $Bad.TenantId = ""

    $Check = Test-ExecutionResultEnvelope $Bad
    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "TENANT_ID_MISSING")
}

Invoke-Test "19 missing project blocked" {
    $Bad = $Valid.PSObject.Copy()
    $Bad.ProjectId = ""

    $Check = Test-ExecutionResultEnvelope $Bad
    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "PROJECT_ID_MISSING")
}

Invoke-Test "20 invalid status blocked" {
    $Bad = $Valid.PSObject.Copy()
    $Bad.Status = "UNKNOWN_STATUS"

    $Check = Test-ExecutionResultEnvelope $Bad
    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "STATUS_INVALID")
}

Invoke-Test "21 negative findings blocked" {
    $Bad = $Valid.PSObject.Copy()
    $Bad.Findings = -1

    $Check = Test-ExecutionResultEnvelope $Bad
    ($Check.Valid -eq $false) -and
    ($Check.Reason -eq "FINDINGS_INVALID")
}

Invoke-Test "22 redacted output valid" {
    $Redacted = New-ExecutionResultEnvelope `
        -Success $true `
        -Status "REDACTED" `
        -ExecutionId "EXEC-7H57-002" `
        -TenantId "TENANT-001" `
        -ClientId "CLIENT-001" `
        -ProjectId "PROJECT-001" `
        -WorkerId "MAYA" `
        -Output "[REDACTED]" `
        -Redacted $true `
        -Findings 1 `
        -Reason "SENSITIVE_DATA_REDACTED"

    (Test-ExecutionResultEnvelope $Redacted).Valid -eq $true
}

Invoke-Test "23 config captures no secrets or payloads" {
    $Config = Get-ExecutionResultContractConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 protected result is single object" {
    $Result = Protect-ExecutionResultEnvelope $Valid
    @($Result).Count -eq 1
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-57 PASS : {0} FAIL : {1}" -f $Pass,$Fail)

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan