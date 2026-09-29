# BK AI WORKERS
# OPENAI REAL AUTH CHECK
# PHASE 7F-7C

param()

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$secretPath = Join-Path $projectRoot ".secrets\openai.secret.dpapi"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " OPENAI REAL AUTH CHECK"
Write-Host " PHASE 7F-7C"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : OPENAI"
Write-Host "REQUEST  : GET /v1/models"
Write-Host ""

if (!(Test-Path -LiteralPath $secretPath)) {
    Write-Host "CREDENTIAL : NOT FOUND"
    exit 1
}

Write-Host "CREDENTIAL FILE : PRESENT"
Write-Host "STORAGE         : DPAPI"

try {
    $encrypted = Get-Content -LiteralPath $secretPath -Raw
    $secureCredential = ConvertTo-SecureString $encrypted
}
catch {
    Write-Host "DPAPI : DECRYPTION ERROR"
    exit 1
}

$credentialPtr = $null
$plainCredential = $null

try {
    $credentialPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCredential)
    $plainCredential = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($credentialPtr)

    if ([string]::IsNullOrWhiteSpace($plainCredential)) {
        Write-Host "CREDENTIAL : EMPTY"
        exit 1
    }

    $headers = @{
        "Authorization" = "Bearer $plainCredential"
    }

    $uri = "https://api.openai.com/v1/models"

    Write-Host "AUTHENTICATION : TESTING"
    Write-Host "SECRET         : [PROTECTED]"
    Write-Host ""

    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method Get `
        -Headers $headers `
        -TimeoutSec 30

    $models = @($response.data)

    Write-Host "============================================"
    Write-Host " OPENAI AUTH RESULT"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "STATUS          : SUCCESS"
    Write-Host "AUTHENTICATION  : VALID"
    Write-Host "PROVIDER        : OPENAI"
    Write-Host "MODELS RETURNED : $($models.Count)"
    Write-Host "SECRET          : [PROTECTED]"
    Write-Host "SECRET EXPOSED  : NO"
    Write-Host ""
    Write-Host "GENERATION      : NONE"
    Write-Host "WORKER ACTION   : NONE"
    Write-Host "FINANCE         : BLOCKED"
    Write-Host "EXTERNAL ACTION : NONE"
    Write-Host ""

    $sample = $models |
        Where-Object { $_.id -match "^gpt-" } |
        Select-Object -First 5 -ExpandProperty id

    if ($sample) {
        Write-Host "GPT MODELS DETECTED :"
        $sample | ForEach-Object {
            Write-Host " - $_"
        }
    }

    Write-Host ""
    Write-Host "OPENAI REAL AUTH : READY"
}
catch {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " OPENAI AUTH RESULT"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "STATUS : ERROR"
    Write-Host "AUTHENTICATION : FAILED"
    Write-Host "DETAIL : $($_.Exception.Message)"
    Write-Host "SECRET : [PROTECTED]"
    exit 1
}
finally {
    if ($null -ne $credentialPtr) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($credentialPtr)
    }

    $plainCredential = $null
}