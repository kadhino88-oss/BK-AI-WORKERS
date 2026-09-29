# BK AI WORKERS
# MAYA - INTELLIGENCE ENGINE
# PHASE 7G-4
# PROVIDER ENGINE INTEGRATION

param(
    [Parameter(Mandatory=$true)]
    [string]$Request,

    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$WorkerId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string]$ContextPath,

    [Parameter(Mandatory=$true)]
    [string]$MemoryPath
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$providerEngine = Join-Path $projectRoot "core\ai\AI-PROVIDER-ENGINE.ps1"
$runtimePath = Join-Path $projectRoot "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MAYA - INTELLIGENCE ENGINE"
Write-Host " PHASE 7G-4"
Write-Host " PROVIDER ENGINE INTEGRATION"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT   : $ClientId"
Write-Host "PROJECT  : $ProjectId"
Write-Host "WORKER   : $WorkerId"
Write-Host "TASK     : $TaskId"
Write-Host ""

if ($WorkerId -ne "MAYA") {
    Write-Host "WORKER IDENTITY : INVALID"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Request)) {
    Write-Host "REQUEST : INVALID"
    exit 1
}

if (!(Test-Path -LiteralPath $ContextPath)) {
    Write-Host "CONTEXT : NOT FOUND"
    exit 1
}

if (!(Test-Path -LiteralPath $MemoryPath)) {
    Write-Host "MEMORY : NOT FOUND"
    exit 1
}

if (!(Test-Path -LiteralPath $providerEngine)) {
    Write-Host "PROVIDER ENGINE : NOT FOUND"
    exit 1
}

try {
    $context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "CONTEXT JSON : INVALID"
    exit 1
}

$contextClient = $context.client_id
$contextProject = $context.project_id
$contextWorker = $context.worker_id

if ([string]::IsNullOrWhiteSpace($contextClient) -and $context.context) {
    $contextClient = $context.context.client_id
    $contextProject = $context.context.project_id
    $contextWorker = $context.context.worker_id
}

if ($contextClient -ne $ClientId -or
    $contextProject -ne $ProjectId -or
    $contextWorker -ne $WorkerId) {
    Write-Host "CONTEXT IDENTITY : MISMATCH"
    exit 1
}

Write-Host "IDENTITY : VALID"
Write-Host "CONTEXT  : VALID"

try {
    $memory = Get-Content -LiteralPath $MemoryPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "MEMORY JSON : INVALID"
    exit 1
}

Write-Host "MEMORY   : LOADED"

Write-Host ""
Write-Host "============================================"
Write-Host " MAYA -> PROVIDER ENGINE"
Write-Host "============================================"
Write-Host ""

& $providerEngine `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId "MAYA" `
    -TaskId $TaskId `
    -Objective $Request `
    -Provider "OPENAI" `
    -Model "gpt-5.6-luna" `
    -ContextPath $ContextPath `
    -MemoryPath $MemoryPath

$providerExit = $LASTEXITCODE

$providerResultPath = Join-Path $runtimePath "PROVIDER-$TaskId.json"

if (!(Test-Path -LiteralPath $providerResultPath)) {
    Write-Host "PROVIDER RESULT : NOT FOUND"
    exit 1
}

try {
    $providerResult = Get-Content -LiteralPath $providerResultPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "PROVIDER RESULT JSON : INVALID"
    exit 1
}

if ($providerResult.client_id -ne $ClientId -or
    $providerResult.project_id -ne $ProjectId -or
    $providerResult.worker -ne "MAYA" -or
    $providerResult.task_id -ne $TaskId) {
    Write-Host "PROVIDER RESULT IDENTITY : INVALID"
    exit 1
}

if ($providerResult.security_status -ne "VALID") {
    Write-Host "PROVIDER SECURITY : INVALID"
    exit 1
}

if ($providerResult.financial_actions -ne $false) {
    Write-Host "FINANCE : ERROR"
    exit 1
}

if ($providerResult.external_actions -ne $false) {
    Write-Host "EXTERNAL : ERROR"
    exit 1
}

Write-Host ""
Write-Host "============================================"
Write-Host " MAYA RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "REQUESTED PROVIDER : OPENAI"
Write-Host "MODEL              : gpt-5.6-luna"
Write-Host "PROVIDER STATUS    : $($providerResult.status)"
Write-Host "PROVIDER MODE      : $($providerResult.mode)"
Write-Host "FALLBACK           : $($providerResult.fallback)"
Write-Host "SECURITY           : $($providerResult.security_status)"
Write-Host "FINANCE            : BLOCKED"
Write-Host "EXTERNAL           : BLOCKED"
Write-Host ""

$mayaOutput = [ordered]@{
    status = $providerResult.status
    worker = "MAYA"
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    request = $Request
    provider = $providerResult.provider
    model = $providerResult.model
    mode = $providerResult.mode
    fallback = $providerResult.fallback
    fallback_reason = $providerResult.fallback_reason
    answer = $providerResult.answer
    recommendations = $providerResult.recommendations
    next_action = $providerResult.next_action
    security_status = $providerResult.security_status
    financial_actions = $providerResult.financial_actions
    external_actions = $providerResult.external_actions
    context_loaded = $true
    memory_loaded = $true
    generated_at = (Get-Date).ToString("o")
}

$outputPath = Join-Path $runtimePath "MAYA-$TaskId.json"

$mayaOutput |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host "OUTPUT : $outputPath"
Write-Host ""

if ($providerResult.status -eq "SUCCESS") {
    Write-Host "MAYA ENGINE : SUCCESS"
    exit 0
}

if ($providerResult.status -eq "FALLBACK") {
    Write-Host "MAYA ENGINE : FALLBACK LOCAL"
    exit 0
}

Write-Host "MAYA ENGINE : ERROR"
exit 1