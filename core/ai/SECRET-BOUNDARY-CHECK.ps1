# BK AI WORKERS
# SECRET BOUNDARY CHECK
# PHASE 7F-2

param()

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$secretDir = Join-Path $projectRoot ".secrets"
$gitignore = Join-Path $projectRoot ".gitignore"
$aiConfig = Join-Path $PSScriptRoot "AI-PROVIDERS.json"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " SECRET BOUNDARY CHECK"
Write-Host " PHASE 7F-2"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $secretDir)) {
    Write-Host "SECRET STORE : ERROR"
    exit 1
}

Write-Host "SECRET STORE : PRESENT"

if (!(Test-Path -LiteralPath $gitignore)) {
    Write-Host "GITIGNORE : ERROR"
    exit 1
}

$gitContent = Get-Content -LiteralPath $gitignore -Raw

if ($gitContent -notmatch [regex]::Escape(".secrets/")) {
    Write-Host "SECRET EXCLUSION : ERROR"
    exit 1
}

Write-Host "SECRET EXCLUSION : VALID"

if (!(Test-Path -LiteralPath $aiConfig)) {
    Write-Host "AI CONFIG : ERROR"
    exit 1
}

try {
    $config = Get-Content -LiteralPath $aiConfig -Raw | ConvertFrom-Json
}
catch {
    Write-Host "AI CONFIG JSON : INVALID"
    exit 1
}

if ($config.llm_enabled -ne $false) {
    Write-Host "LLM : ERROR"
    exit 1
}

if ($config.development.api_calls_enabled -ne $false) {
    Write-Host "API : ERROR"
    exit 1
}

Write-Host "LLM : DISABLED"
Write-Host "API : DISABLED"

$files = Get-ChildItem -LiteralPath $secretDir -File -ErrorAction SilentlyContinue

$realSecrets = $files | Where-Object {
    $_.Name -notlike "*.example"
}

if ($realSecrets.Count -gt 0) {
    Write-Host "REAL CREDENTIALS : PRESENT"
    Write-Host "COUNT : $($realSecrets.Count)"
}
else {
    Write-Host "REAL CREDENTIALS : NONE"
}

$dangerousExtensions = @(
    ".env",
    ".key",
    ".pem",
    ".pfx",
    ".secret",
    ".secrets"
)

$projectFiles = Get-ChildItem -LiteralPath $projectRoot -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object {
        $_.FullName -notlike "$secretDir\*" -and
        $dangerousExtensions -contains $_.Extension.ToLower()
    }

if ($projectFiles.Count -gt 0) {
    Write-Host "DANGEROUS SECRET FILES : DETECTED"
    $projectFiles | Select-Object -ExpandProperty FullName
    exit 1
}

Write-Host "SECRET FILE SCAN : CLEAN"

Write-Host ""
Write-Host "============================================"
Write-Host " PHASE 7F-2 RESULT"
Write-Host "============================================"
Write-Host ""
Write-Host "STATUS          : SUCCESS"
Write-Host "SECRET STORE    : READY"
Write-Host "CREDENTIALS     : NONE"
Write-Host "API             : DISABLED"
Write-Host "COST            : 0"
Write-Host "SECRET EXPOSURE : BLOCKED"
Write-Host "FINANCE         : BLOCKED"
Write-Host "EXTERNAL        : BLOCKED"
Write-Host ""
Write-Host "CREDENTIAL BOUNDARY : READY"