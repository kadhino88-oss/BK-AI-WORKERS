# BK AI WORKERS
# LIVE PROVIDER SAFETY GATE
# PHASE 7F-4

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("NONE","OPENAI","ANTHROPIC")]
    [string]$Provider,

    [Parameter(Mandatory=$false)]
    [ValidateSet("DRY_RUN","LIVE")]
    [string]$Mode = "DRY_RUN"
)

$ErrorActionPreference = "Stop"

$configPath = Join-Path $PSScriptRoot "AI-PROVIDERS.json"
$credentialLoader = Join-Path $PSScriptRoot "SECURE-CREDENTIAL-LOADER.ps1"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " LIVE PROVIDER SAFETY GATE"
Write-Host " PHASE 7F-4"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : $Provider"
Write-Host "MODE     : $Mode"
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

if ($config.security.secret_exposure -ne $false) {
    Write-Host "SECRET EXPOSURE : ERROR"
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

if (!(Test-Path -LiteralPath $credentialLoader)) {
    Write-Host "CREDENTIAL LOADER : ERROR"
    exit 1
}

Write-Host "CREDENTIAL LOADER : PRESENT"

if ($Mode -eq "DRY_RUN") {
    Write-Host ""
    Write-Host "============================================"
    Write-Host " DRY-RUN SAFETY RESULT"
    Write-Host "============================================"
    Write-Host ""
    Write-Host "NETWORK CALL : DISABLED"
    Write-Host "CREDENTIAL   : NOT LOADED"
    Write-Host "COST         : 0"
    Write-Host "SIDE EFFECTS : NONE"
    Write-Host "SECURITY     : VALID"
    Write-Host ""
    Write-Host "LIVE PROVIDER GATE : READY"
    exit 0
}

if ($Mode -eq "LIVE") {
    Write-Host ""
    Write-Host "LIVE MODE REQUESTED"
    Write-Host ""

    if ($config.llm_enabled -ne $true) {
        Write-Host "LIVE MODE : BLOCKED"
        Write-Host "REASON    : LLM GLOBAL DISABLED"
        exit 1
    }

    if ($config.development.api_calls_enabled -ne $true) {
        Write-Host "LIVE MODE : BLOCKED"
        Write-Host "REASON    : API CALLS DISABLED"
        exit 1
    }

    Write-Host "LIVE MODE : CONFIGURED"
    Write-Host "NETWORK   : NOT EXECUTED BY 7F-4"
    exit 0
}