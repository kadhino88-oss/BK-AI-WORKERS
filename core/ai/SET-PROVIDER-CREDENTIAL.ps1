# BK AI WORKERS
# SECURE PROVIDER CREDENTIAL SETUP
# PHASE 7F-7A

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
Write-Host " SECURE PROVIDER CREDENTIAL SETUP"
Write-Host " PHASE 7F-7A"
Write-Host "============================================"
Write-Host ""

Write-Host "PROVIDER : $Provider"
Write-Host ""
Write-Host "La cle sera saisie sans etre affichee."
Write-Host "Elle sera chiffrée avec Windows DPAPI."
Write-Host ""

$secure = Read-Host "Entre la cle API" -AsSecureString

if ($null -eq $secure) {
    Write-Host "CREDENTIAL : ERROR"
    exit 1
}

if ($secure.Length -lt 10) {
    Write-Host "CREDENTIAL : INVALID"
    exit 1
}

try {
    $encrypted = ConvertFrom-SecureString $secure
}
catch {
    Write-Host "ENCRYPTION : ERROR"
    exit 1
}

$fileName = switch ($Provider) {
    "OPENAI" { "openai.secret.dpapi" }
    "ANTHROPIC" { "anthropic.secret.dpapi" }
}

$path = Join-Path $secretDir $fileName

[System.IO.File]::WriteAllText(
    $path,
    $encrypted,
    [System.Text.UTF8Encoding]::new($false)
)

Write-Host ""
Write-Host "============================================"
Write-Host " SECURE CREDENTIAL RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "STATUS          : SUCCESS"
Write-Host "PROVIDER        : $Provider"
Write-Host "STORAGE         : DPAPI"
Write-Host "SECRET          : [PROTECTED]"
Write-Host "SECRET EXPOSED  : NO"
Write-Host "API CALL        : NONE"
Write-Host "COST            : 0"
Write-Host ""
Write-Host "OUTPUT          : $path"
Write-Host ""
Write-Host "SECURE CREDENTIAL STORAGE : READY"