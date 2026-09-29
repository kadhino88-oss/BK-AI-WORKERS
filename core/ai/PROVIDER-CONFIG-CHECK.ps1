# BK AI WORKERS
# PROVIDER CONFIG CHECK
# PHASE 7F-1

param()

$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
$configPath = Join-Path $scriptRoot "AI-PROVIDERS.json"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " PROVIDER CONFIG CHECK"
Write-Host " PHASE 7F-1"
Write-Host "============================================"
Write-Host ""

Write-Host "SCRIPT ROOT : $scriptRoot"
Write-Host "CONFIG PATH : $configPath"
Write-Host ""

if (!(Test-Path -LiteralPath $configPath)) {
    Write-Host "CONFIG : ERROR"
    Write-Host "DETAIL : AI-PROVIDERS.json introuvable"
    exit 1
}

Write-Host "CONFIG FILE : FOUND"

try {
    $rawConfig = Get-Content -LiteralPath $configPath -Raw
    $config = $rawConfig | ConvertFrom-Json
}
catch {
    Write-Host "JSON : INVALID"
    Write-Host "DETAIL : $($_.Exception.Message)"
    exit 1
}

Write-Host "JSON : VALID"

if ($config.llm_enabled -ne $false) {
    Write-Host "LLM : ERROR"
    exit 1
}

Write-Host "LLM : DISABLED"

if ($config.providers.anthropic.enabled -ne $false) {
    Write-Host "ANTHROPIC : ERROR"
    exit 1
}

if ($config.providers.openai.enabled -ne $false) {
    Write-Host "OPENAI : ERROR"
    exit 1
}

Write-Host "ANTHROPIC : NOT ACTIVE"
Write-Host "OPENAI    : NOT ACTIVE"

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

if ($config.development.api_calls_enabled -ne $false) {
    Write-Host "API CALLS : ERROR"
    exit 1
}

if ($config.development.cost -ne 0) {
    Write-Host "COST : ERROR"
    exit 1
}

Write-Host "CLIENT ISOLATION : VALID"
Write-Host "PROJECT ISOLATION : VALID"
Write-Host "WORKER ISOLATION : VALID"
Write-Host "SECRET EXPOSURE : BLOCKED"
Write-Host "FINANCE         : BLOCKED"
Write-Host "EXTERNAL        : BLOCKED"
Write-Host "API CALLS       : DISABLED"
Write-Host "COST            : 0"

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 7F-1 RESULT"
Write-Host "============================================"
Write-Host ""
Write-Host "STATUS   : SUCCESS"
Write-Host "MODE     : LOCAL"
Write-Host "API      : DISABLED"
Write-Host "COST     : 0"
Write-Host "SECURITY : VALID"
Write-Host ""
Write-Host "PROVIDER CONFIG : READY"
Write-Host ""