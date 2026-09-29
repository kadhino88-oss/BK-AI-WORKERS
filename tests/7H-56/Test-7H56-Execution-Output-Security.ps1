Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-output-security"
$RuntimeFile = Join-Path $RuntimeRoot "Execution-Output-Security.ps1"
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

$BaseContext = @{
    ExecutionId = "EXEC-7H56-001"
    TenantId    = "TENANT-001"
    ClientId    = "CLIENT-001"
    ProjectId   = "PROJECT-001"
    WorkerId    = "MAYA"
}

Invoke-Test "01 config enabled" {
    (Get-ExecutionOutputSecurityConfig).enabled -eq $true
}

Invoke-Test "02 integration enabled" {
    (Get-ExecutionOutputSecurityConfig).integrationEnabled -eq $true
}

Invoke-Test "03 sanitize enabled" {
    (Get-ExecutionOutputSecurityConfig).sanitizeEnabled -eq $true
}

Invoke-Test "04 clean execution output allowed" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "Bonjour Kader"
    ($Result.Success -eq $true) -and
    ($Result.Status -eq "CLEAN") -and
    ($Result.Output -eq "Bonjour Kader")
}

Invoke-Test "05 password redacted" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "password=SuperSecret123"
    ($Result.Success -eq $true) -and
    ($Result.Redacted -eq $true) -and
    ($Result.Output -notmatch "SuperSecret123")
}

Invoke-Test "06 api key redacted" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "api_key=ABC123SECRET"
    $Result.Output -notmatch "ABC123SECRET"
}

Invoke-Test "07 bearer token redacted" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456"
    $Result.Output -notmatch "abcdefghijklmnopqrstuvwxyz123456"
}

Invoke-Test "08 nested object sanitized" {
    $Object = [ordered]@{
        status = "ok"
        credentials = [ordered]@{
            password = "HiddenNestedSecret"
        }
    }

    $Result = Protect-ExecutionOutput @BaseContext -Output $Object

    ($Result.Success -eq $true) -and
    ($Result.Output -notmatch "HiddenNestedSecret")
}

Invoke-Test "09 array sanitized" {
    $Object = @(
        "normal"
        "api_key=HiddenArraySecret"
    )

    $Result = Protect-ExecutionOutput @BaseContext -Output $Object

    $Result.Output -notmatch "HiddenArraySecret"
}

Invoke-Test "10 large output blocked" {
    $Huge = "A" * 200001

    $Result = Protect-ExecutionOutput @BaseContext -Output $Huge

    ($Result.Success -eq $false) -and
    ($Result.Status -eq "BLOCKED") -and
    ($Result.Reason -eq "OUTPUT_TOO_LARGE")
}

Invoke-Test "11 null output safe" {
    $Result = Protect-ExecutionOutput @BaseContext -Output $null

    ($Result.Success -eq $true) -and
    ($Result.Status -eq "CLEAN")
}

Invoke-Test "12 empty output safe" {
    $Result = Protect-ExecutionOutput @BaseContext -Output ""

    ($Result.Success -eq $true) -and
    ($Result.Status -eq "CLEAN")
}

Invoke-Test "13 tenant preserved" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "ok"
    $Result.TenantId -eq "TENANT-001"
}

Invoke-Test "14 client preserved" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "ok"
    $Result.ClientId -eq "CLIENT-001"
}

Invoke-Test "15 project preserved" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "ok"
    $Result.ProjectId -eq "PROJECT-001"
}

Invoke-Test "16 worker preserved" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "ok"
    $Result.WorkerId -eq "MAYA"
}

Invoke-Test "17 execution id preserved" {
    $Result = Protect-ExecutionOutput @BaseContext -Output "ok"
    $Result.ExecutionId -eq "EXEC-7H56-001"
}

Invoke-Test "18 missing execution blocked" {
    $Context = $BaseContext.Clone()
    $Context.ExecutionId = ""

    $Result = Protect-ExecutionOutput @Context -Output "ok"

    ($Result.Success -eq $false) -and
    ($Result.Status -eq "BLOCKED") -and
    ($Result.Reason -eq "CONTEXT_INCOMPLETE")
}

Invoke-Test "19 missing tenant blocked" {
    $Context = $BaseContext.Clone()
    $Context.TenantId = ""

    $Result = Protect-ExecutionOutput @Context -Output "ok"

    ($Result.Success -eq $false) -and
    ($Result.Reason -eq "CONTEXT_INCOMPLETE")
}

Invoke-Test "20 secret absent from final output" {
    $Secret = "NeverExposeThisValue777"

    $Result = Protect-ExecutionOutput @BaseContext -Output "password=$Secret"

    $Result.Output -notmatch [regex]::Escape($Secret)
}

Invoke-Test "21 findings reported" {
    $Result = Protect-ExecutionOutput @BaseContext -Output @(
        "password=One"
        "api_key=Two"
        "access_token=Three"
    )

    ($Result.Redacted -eq $true) -and
    ($Result.Findings -ge 3)
}

Invoke-Test "22 config captures no credentials" {
    $Text = Get-Content -Raw -Path $ConfigFile

    ($Text -notmatch "(?i)password\s*[:=]") -and
    ($Text -notmatch "(?i)api[_-]?key\s*[:=]") -and
    ($Text -notmatch "(?i)secret\s*[:=]")
}

Invoke-Test "23 config captures no payload" {
    $Config = Get-ExecutionOutputSecurityConfig

    ($Config.captureSecrets -eq $false) -and
    ($Config.capturePayloads -eq $false)
}

Invoke-Test "24 live execution remains disabled" {
    (Get-ExecutionOutputSecurityConfig).liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host ("RESULTATS 7H-56 PASS : {0} FAIL : {1}" -f $Pass,$Fail)
if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
}
else {
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}
Write-Host "==================================================" -ForegroundColor Cyan