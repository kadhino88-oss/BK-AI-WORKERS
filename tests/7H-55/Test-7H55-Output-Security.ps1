Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RuntimeRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\output-security"
$RuntimeFile = Join-Path $RuntimeRoot "Output-Security.ps1"
$ConfigFile  = Join-Path $RuntimeRoot "config.json"

. $RuntimeFile

$script:PassCount = 0
$script:FailCount = 0

function Invoke-Test {

    param(
        [string]$Name,
        [scriptblock]$Action
    )

    try {

        $Result = & $Action

        if ($Result -eq $false) {
            throw "ASSERTION FALSE"
        }

        $script:PassCount++

        Write-Host "PASS $Name" -ForegroundColor Green
    }
    catch {

        $script:FailCount++

        Write-Host "FAIL $Name :: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Invoke-Test "01 config enabled" {

    (Get-OutputSecurityConfig).enabled -eq $true
}

Invoke-Test "02 redaction enabled" {

    (Get-OutputSecurityConfig).redactionEnabled -eq $true
}

Invoke-Test "03 secret detection enabled" {

    (Get-OutputSecurityConfig).secretDetectionEnabled -eq $true
}

Invoke-Test "04 clean output unchanged" {

    $Result = Redact-SensitiveOutput "Bonjour Kader"

    (
        $Result.Status -eq "CLEAN"
    ) -and (
        $Result.Output -eq "Bonjour Kader"
    )
}

Invoke-Test "05 password redacted" {

    $Result = Redact-SensitiveOutput `
        'password=SuperSecret123'

    (
        $Result.Redacted -eq $true
    ) -and (
        $Result.Output -notmatch "SuperSecret123"
    )
}

Invoke-Test "06 api key redacted" {

    $Result = Redact-SensitiveOutput `
        'api_key=ABC123SECRET'

    $Result.Output -notmatch "ABC123SECRET"
}

Invoke-Test "07 bearer token redacted" {

    $Result = Redact-SensitiveOutput `
        'Authorization: Bearer abcdefghijklmnopqrstuvwxyz123456'

    $Result.Output -notmatch "abcdefghijklmnopqrstuvwxyz123456"
}

Invoke-Test "08 OpenAI style key redacted" {

    $Result = Redact-SensitiveOutput `
        'key sk-abcdefghijklmnopqrstuvwxyz123456789'

    $Result.Output -notmatch "sk-abcdefghijklmnopqrstuvwxyz123456789"
}

Invoke-Test "09 GitHub style token redacted" {

    $Result = Redact-SensitiveOutput `
        'token=ghp_abcdefghijklmnopqrstuvwxyz1234567890'

    $Result.Output -notmatch "ghp_abcdefghijklmnopqrstuvwxyz1234567890"
}

Invoke-Test "10 AWS style key redacted" {

    $Result = Redact-SensitiveOutput `
        'accessKey=AKIA1234567890ABCDEF'

    $Result.Output -notmatch "AKIA1234567890ABCDEF"
}

Invoke-Test "11 Google style key redacted" {

    $Result = Redact-SensitiveOutput `
        'apiKey=AIzaSy123456789012345678901234567890'

    $Result.Output -notmatch "AIzaSy123456789012345678901234567890"
}

Invoke-Test "12 multiple findings" {

    $InputText = @"
password=SecretOne
api_key=SecretTwo
access_token=SecretThree
"@

    $Result = Redact-SensitiveOutput $InputText

    (
        $Result.Redacted -eq $true
    ) -and (
        $Result.Findings -ge 3
    )
}

Invoke-Test "13 replacement marker present" {

    $Result = Redact-SensitiveOutput `
        'password=Secret123'

    $Result.Output -match "\[REDACTED\]"
}

Invoke-Test "14 original secret absent" {

    $Secret = "NeverStoreThisSecret123"

    $Result = Redact-SensitiveOutput `
        "password=$Secret"

    $Result.Output -notmatch [regex]::Escape($Secret)
}

Invoke-Test "15 nested object sanitized" {

    $Object = [ordered]@{
        status = "ok"
        user = "demo"
        credentials = [ordered]@{
            password = "HiddenValue"
        }
    }

    $Result = Redact-SensitiveOutput $Object

    $Result.Output -notmatch "HiddenValue"
}

Invoke-Test "16 array sanitized" {

    $Object = @(
        "normal value",
        "api_key=HiddenArraySecret"
    )

    $Result = Redact-SensitiveOutput $Object

    $Result.Output -notmatch "HiddenArraySecret"
}

Invoke-Test "17 null output safe" {

    $Result = Redact-SensitiveOutput $null

    (
        $Result.Success -eq $true
    ) -and (
        $Result.Status -eq "CLEAN"
    )
}

Invoke-Test "18 empty output safe" {

    $Result = Redact-SensitiveOutput ""

    (
        $Result.Success -eq $true
    ) -and (
        $Result.Status -eq "CLEAN"
    )
}

Invoke-Test "19 large output blocked" {

    $Huge = "A" * 200001

    $Result = Redact-SensitiveOutput $Huge

    (
        $Result.Success -eq $false
    ) -and (
        $Result.Status -eq "BLOCKED"
    ) -and (
        $Result.Reason -eq "OUTPUT_TOO_LARGE"
    )
}

Invoke-Test "20 normal output not redacted" {

    $Result = Redact-SensitiveOutput `
        "Execution completed successfully."

    (
        $Result.Redacted -eq $false
    ) -and (
        $Result.Output -eq "Execution completed successfully."
    )
}

Invoke-Test "21 sensitive test reports unsafe input" {

    $Result = Test-SensitiveOutput `
        "password=VerySecretValue"

    (
        $Result.Redacted -eq $true
    ) -and (
        $Result.Findings -ge 1
    )
}

Invoke-Test "22 config has no credential values" {

    $Text = Get-Content `
        -Raw `
        -Path $ConfigFile

    $Forbidden = '(?i)"(?:password|apiKey|api_key|accessToken|refreshToken|secretValue|credentialValue)"\s*:\s*"[^"]+"'

    $Text -notmatch $Forbidden
}

Invoke-Test "23 config has no payload" {

    $Text = Get-Content `
        -Raw `
        -Path $ConfigFile

    $Text -notmatch '(?i)"payload"\s*:'
}

Invoke-Test "24 detection remains simulation safe" {

    $Config = Get-OutputSecurityConfig

    $Config.liveExecutionEnabled -eq $false
}

Write-Host ""
Write-Host "==================================================" -ForegroundColor Cyan
Write-Host "RESULTATS 7H-55 PASS : $script:PassCount FAIL : $script:FailCount" -ForegroundColor Cyan

if ($script:PassCount -eq 24 -and $script:FailCount -eq 0) {

    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green

}
else {

    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Write-Host "==================================================" -ForegroundColor Cyan

Read-Host "Appuie sur Entree pour fermer"