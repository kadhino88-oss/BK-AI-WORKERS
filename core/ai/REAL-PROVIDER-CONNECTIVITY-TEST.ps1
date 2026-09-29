# BK AI WORKERS
# REAL PROVIDER CONNECTIVITY TEST
# PHASE 7F-5

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("OPENAI","ANTHROPIC")]
    [string]$Provider,

    [switch]$ConfirmLive
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "AI-PROVIDERS.json"
$loaderPath = Join-Path $PSScriptRoot "SECURE-CREDENTIAL-LOADER.ps1"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " REAL PROVIDER CONNECTIVITY TEST"
Write-Host " PHASE 7F-5"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : $Provider"
Write-Host ""

if (!(Test-Path -LiteralPath $configPath)) {
    Write-Host "CONFIG : ERROR"
    exit 1
}

try {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "CONFIG JSON : INVALID"
    exit 1
}

Write-Host "CONFIG : VALID"

if (!(Test-Path -LiteralPath $loaderPath)) {
    Write-Host "CREDENTIAL LOADER : ERROR"
    exit 1
}

Write-Host "CREDENTIAL LOADER : PRESENT"

if ($config.security.secret_exposure -ne $false) {
    Write-Host "SECRET EXPOSURE : ERROR"
    exit 1
}

if ($config.security.client_isolation -ne $true) {
    Write-Host "CLIENT ISOLATION : ERROR"
    exit 1
}

if ($config.security.project_isolation -ne $true) {
    Write-Host "PROJECT ISOLATION : ERROR"
    exit 1
}

if ($config.security.worker_isolation -ne $true) {
    Write-Host "WORKER ISOLATION : ERROR"
    exit 1
}

if ($config.security.financial_actions -ne $false) {
    Write-Host "FINANCE : ERROR"
    exit 1
}

if ($config.security.external_actions -ne $false) {
    Write-Host "EXTERNAL : ERROR"
    exit 1
}

Write-Host "SECURITY : VALID"
Write-Host "FINANCE  : BLOCKED"
Write-Host "EXTERNAL : BLOCKED"

if (!$ConfirmLive) {
    Write-Host ""
    Write-Host "LIVE CALL : NOT AUTHORIZED"
    Write-Host "NETWORK   : DISABLED"
    Write-Host "CREDENTIAL: NOT LOADED"
    Write-Host "COST      : 0"
    Write-Host ""
    Write-Host "DRY-RUN CHECK : SUCCESS"
    exit 0
}

Write-Host ""
Write-Host "LIVE CONFIRMATION : RECEIVED"
Write-Host ""

if ($config.llm_enabled -ne $true) {
    Write-Host "LIVE CALL : BLOCKED"
    Write-Host "REASON    : LLM GLOBAL DISABLED"
    exit 1
}

if ($config.development.api_calls_enabled -ne $true) {
    Write-Host "LIVE CALL : BLOCKED"
    Write-Host "REASON    : API CALLS DISABLED"
    exit 1
}

$credentialPath = switch ($Provider) {
    "OPENAI" {
        Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ".secrets") "openai.secret"
    }
    "ANTHROPIC" {
        Join-Path (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) ".secrets") "anthropic.secret"
    }
}

if (!(Test-Path -LiteralPath $credentialPath)) {
    Write-Host "CREDENTIAL : NOT CONFIGURED"
    Write-Host "LIVE CALL  : NOT EXECUTED"
    Write-Host "COST       : 0"
    exit 1
}

$credential = Get-Content -LiteralPath $credentialPath -Raw

if ([string]::IsNullOrWhiteSpace($credential)) {
    Write-Host "CREDENTIAL : EMPTY"
    exit 1
}

$credential = $credential.Trim()

if ($credential.Length -lt 10) {
    Write-Host "CREDENTIAL : INVALID"
    exit 1
}

Write-Host "CREDENTIAL : DETECTED"
Write-Host "SECRET     : [PROTECTED]"

if ($Provider -eq "OPENAI") {
    $headers = @{
        "Authorization" = "Bearer $credential"
    }

    $uri = "https://api.openai.com/v1/models"

    Write-Host "ENDPOINT   : OPENAI /v1/models"
    Write-Host "REQUEST    : GET"
}
else {
    $headers = @{
        "x-api-key" = $credential
        "anthropic-version" = "2023-06-01"
    }

    $uri = "https://api.anthropic.com/v1/models"

    Write-Host "ENDPOINT   : ANTHROPIC /v1/models"
    Write-Host "REQUEST    : GET"
}

try {
    $response = Invoke-RestMethod `
        -Uri $uri `
        -Method Get `
        -Headers $headers `
        -TimeoutSec 30

    $count = 0

    if ($null -ne $response.data) {
        $count = @($response.data).Count
    }

    Write-Host ""
    Write-Host "============================================"
    Write-Host " CONNECTIVITY RESULT"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "STATUS          : SUCCESS"
    Write-Host "AUTHENTICATION  : VALID"
    Write-Host "PROVIDER        : $Provider"
    Write-Host "MODELS RETURNED : $count"
    Write-Host "SECRET          : [PROTECTED]"
    Write-Host "FINANCE         : BLOCKED"
    Write-Host "EXTERNAL ACTION : NONE"
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " CONNECTIVITY RESULT"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "STATUS : ERROR"
    Write-Host "PROVIDER : $Provider"
    Write-Host "DETAIL : $($_.Exception.Message)"
    Write-Host ""
    Write-Host "SECRET : [PROTECTED]"
    exit 1
}