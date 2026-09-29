# BK AI WORKERS
# SECURE CREDENTIAL LOADER
# PHASE 7F-7B
# DPAPI INTEGRATION

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("OPENAI","ANTHROPIC")]
    [string]$Provider
)

$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$secretDir = Join-Path $projectRoot ".secrets"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " SECURE CREDENTIAL LOADER"
Write-Host " PHASE 7F-7B"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : $Provider"

$configPath = Join-Path $PSScriptRoot "AI-PROVIDERS.json"

if (!(Test-Path -LiteralPath $configPath)) {
    Write-Host "AI CONFIG : ERROR"
    exit 1
}

try {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "AI CONFIG JSON : INVALID"
    exit 1
}

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

Write-Host "SECURITY : VALID"

$fileName = switch ($Provider) {
    "OPENAI"    { "openai.secret.dpapi" }
    "ANTHROPIC" { "anthropic.secret.dpapi" }
}

$credentialPath = Join-Path $secretDir $fileName

if (!(Test-Path -LiteralPath $credentialPath)) {
    Write-Host "CREDENTIAL : NOT CONFIGURED"
    Write-Host "STATUS     : SAFE"
    Write-Host "ACTION     : NO SECRET LOADED"
    Write-Host "API CALL   : DISABLED"
    Write-Host "COST       : 0"
    exit 0
}

Write-Host "CREDENTIAL FILE : PRESENT"
Write-Host "STORAGE         : DPAPI"

try {
    $encrypted = Get-Content -LiteralPath $credentialPath -Raw
    $secureCredential = ConvertTo-SecureString $encrypted
}
catch {
    Write-Host "DPAPI DECRYPTION : ERROR"
    exit 1
}

if ($null -eq $secureCredential) {
    Write-Host "CREDENTIAL : INVALID"
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

    if ($plainCredential.Length -lt 10) {
        Write-Host "CREDENTIAL : INVALID"
        exit 1
    }

    Write-Host ""
    Write-Host "DPAPI DECRYPTION : SUCCESS"
    Write-Host "CREDENTIAL       : VALID"
    Write-Host "SECRET           : [PROTECTED]"
    Write-Host "SECRET EXPOSURE  : BLOCKED"
    Write-Host "API CALL         : NONE"
    Write-Host "COST             : 0"
}
finally {
    if ($null -ne $credentialPtr) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($credentialPtr)
    }

    $plainCredential = $null
}

Write-Host ""
Write-Host "============================================"
Write-Host " CREDENTIAL LOADER RESULT"
Write-Host "============================================"
Write-Host ""
Write-Host "STATUS          : SUCCESS"
Write-Host "PROVIDER        : $Provider"
Write-Host "STORAGE         : DPAPI"
Write-Host "SECRET          : PROTECTED"
Write-Host "SECRET EXPOSED  : NO"
Write-Host "API CALL        : NONE"
Write-Host "COST            : 0"
Write-Host ""
Write-Host "SECURE CREDENTIAL LOADER : READY"