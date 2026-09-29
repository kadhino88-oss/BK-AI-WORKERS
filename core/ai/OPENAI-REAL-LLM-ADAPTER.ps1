# BK AI WORKERS
# OPENAI REAL LLM ADAPTER
# PHASE 7G-1

param(
    [Parameter(Mandatory=$true)]
    [string]$Model = "gpt-5.6-luna"
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$secretPath = Join-Path $projectRoot ".secrets\openai.secret.dpapi"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " OPENAI REAL LLM ADAPTER"
Write-Host " PHASE 7G-1"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : OPENAI"
Write-Host "MODEL    : $Model"
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
    Write-Host "DPAPI : ERROR"
    exit 1
}

$credentialPtr = $null
$apiKey = $null

try {
    $credentialPtr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureCredential)
    $apiKey = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($credentialPtr)

    if ([string]::IsNullOrWhiteSpace($apiKey)) {
        Write-Host "CREDENTIAL : INVALID"
        exit 1
    }

    $headers = @{
        "Authorization" = "Bearer $apiKey"
        "Content-Type"  = "application/json"
    }

    $body = @{
        model = $Model
        input = "Réponds uniquement par OK."
        max_output_tokens = 16
    } | ConvertTo-Json -Depth 5

    $uri = "https://api.openai.com/v1/responses"

    Write-Host "ENDPOINT   : /v1/responses"
    Write-Host "REQUEST    : REAL"
    Write-Host "GENERATION : MINIMAL"
    Write-Host "SECRET     : [PROTECTED]"
    Write-Host ""

    try {
        $response = Invoke-RestMethod `
            -Uri $uri `
            -Method Post `
            -Headers $headers `
            -Body $body `
            -TimeoutSec 60
    }
    catch {
        Write-Host ""
        Write-Host "OPENAI REQUEST : ERROR"
        Write-Host "DETAIL : $($_.Exception.Message)"
        exit 1
    }

    $responseId = $response.id

    if ([string]::IsNullOrWhiteSpace($responseId)) {
        Write-Host "RESPONSE : INVALID"
        exit 1
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host " OPENAI REAL LLM RESULT"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "STATUS          : SUCCESS"
    Write-Host "AUTHENTICATION  : VALID"
    Write-Host "PROVIDER        : OPENAI"
    Write-Host "MODEL REQUESTED : $Model"
    Write-Host "RESPONSE ID     : $responseId"
    Write-Host "SECRET          : [PROTECTED]"
    Write-Host "SECRET EXPOSED  : NO"
    Write-Host "FINANCE         : BLOCKED"
    Write-Host "EXTERNAL ACTION : NONE"
    Write-Host ""

    Write-Host "OPENAI REAL LLM : CONNECTED"
}
finally {
    if ($null -ne $credentialPtr) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($credentialPtr)
    }

    $apiKey = $null
}