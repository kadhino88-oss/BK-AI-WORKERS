# BK AI WORKERS
# CONTROLLED LIVE ACTIVATION
# PHASE 7F-6

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("OPENAI","ANTHROPIC")]
    [string]$Provider,

    [Parameter(Mandatory=$false)]
    [ValidateSet("CHECK","ARM")]
    [string]$Action = "CHECK"
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "AI-PROVIDERS.json"
$gatePath = Join-Path $PSScriptRoot "LIVE-PROVIDER-SAFETY-GATE.ps1"
$loaderPath = Join-Path $PSScriptRoot "SECURE-CREDENTIAL-LOADER.ps1"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " CONTROLLED LIVE ACTIVATION"
Write-Host " PHASE 7F-6"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : $Provider"
Write-Host "ACTION   : $Action"
Write-Host ""

if (!(Test-Path -LiteralPath $configPath)) {
    Write-Host "CONFIG : ERROR"
    exit 1
}

if (!(Test-Path -LiteralPath $gatePath)) {
    Write-Host "SAFETY GATE : ERROR"
    exit 1
}

if (!(Test-Path -LiteralPath $loaderPath)) {
    Write-Host "CREDENTIAL LOADER : ERROR"
    exit 1
}

$config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json

Write-Host "CONFIG              : VALID"
Write-Host "SAFETY GATE         : PRESENT"
Write-Host "CREDENTIAL LOADER   : PRESENT"

if ($config.security.client_isolation -ne $true) {
    Write-Host "CLIENT ISOLATION    : ERROR"
    exit 1
}

if ($config.security.project_isolation -ne $true) {
    Write-Host "PROJECT ISOLATION   : ERROR"
    exit 1
}

if ($config.security.worker_isolation -ne $true) {
    Write-Host "WORKER ISOLATION    : ERROR"
    exit 1
}

if ($config.security.secret_exposure -ne $false) {
    Write-Host "SECRET EXPOSURE     : ERROR"
    exit 1
}

if ($config.security.financial_actions -ne $false) {
    Write-Host "FINANCE             : ERROR"
    exit 1
}

if ($config.security.external_actions -ne $false) {
    Write-Host "EXTERNAL            : ERROR"
    exit 1
}

Write-Host "SECURITY            : VALID"
Write-Host "FINANCE             : BLOCKED"
Write-Host "EXTERNAL            : BLOCKED"
Write-Host "SECRET EXPOSURE     : BLOCKED"

if ($Action -eq "CHECK") {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " ACTIVATION CHECK"
    Write-Host "============================================"
    Write-Host ""

    Write-Host "CURRENT LLM         : $($config.llm_enabled)"
    Write-Host "CURRENT API CALLS   : $($config.development.api_calls_enabled)"
    Write-Host "CURRENT MODE        : $($config.mode)"
    Write-Host "CURRENT PROVIDER    : $($config.active_provider)"

    Write-Host ""
    Write-Host "LIVE STATUS         : NOT ARMED"
    Write-Host "NETWORK             : DISABLED"
    Write-Host "COST                : 0"
    Write-Host ""
    Write-Host "PHASE 7F-6 CHECK : SUCCESS"
    exit 0
}

if ($Action -eq "ARM") {
    Write-Host ""
    Write-Host "ARM REQUEST RECEIVED"
    Write-Host ""

    Write-Host "IMPORTANT :"
    Write-Host "This script does NOT enable the provider automatically."
    Write-Host "Global configuration remains unchanged."
    Write-Host ""

    Write-Host "LLM CURRENTLY      : $($config.llm_enabled)"
    Write-Host "API CALLS CURRENTLY: $($config.development.api_calls_enabled)"
    Write-Host ""

    if ($config.llm_enabled -ne $true) {
        Write-Host "ACTIVATION : BLOCKED"
        Write-Host "REASON     : llm_enabled = false"
        Write-Host ""
        Write-Host "NO FILE MODIFIED"
        Write-Host "NO API CALL"
        Write-Host "COST = 0"
        exit 1
    }

    if ($config.development.api_calls_enabled -ne $true) {
        Write-Host "ACTIVATION : BLOCKED"
        Write-Host "REASON     : api_calls_enabled = false"
        Write-Host ""
        Write-Host "NO FILE MODIFIED"
        Write-Host "NO API CALL"
        Write-Host "COST = 0"
        exit 1
    }

    Write-Host "ACTIVATION : ARMED"
    Write-Host "PROVIDER   : $Provider"
    Write-Host "NETWORK    : PERMITTED BY CONFIG"
    Write-Host ""
    Write-Host "NO REQUEST SENT BY THIS SCRIPT"
    exit 0
}