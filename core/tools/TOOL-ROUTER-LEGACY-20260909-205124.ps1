# BK AI WORKERS
# TOOL ROUTER
# PHASE 7H-7

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet("LEA","NOAH","ALEX","MAYA","LUCAS","EMMA","SAM")]
    [string]$WorkerId,

    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string]$ToolId,

    [Parameter(Mandatory=$true)]
    [string]$Action
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$toolsDir = Join-Path $projectRoot "core\tools"
$contractsDir = Join-Path $toolsDir "contracts"
$runtimeDir = Join-Path $projectRoot "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " TOOL ROUTER"
Write-Host " PHASE 7H-7"
Write-Host "============================================"
Write-Host ""

Write-Host "WORKER  : $WorkerId"
Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "TASK    : $TaskId"
Write-Host "TOOL    : $ToolId"
Write-Host "ACTION  : $Action"
Write-Host ""

$contractPath = Join-Path $contractsDir "$ToolId.json"

if (!(Test-Path -LiteralPath $contractPath)) {
    Write-Host "TOOL CONTRACT : NOT FOUND"
    exit 1
}

try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "TOOL CONTRACT : INVALID"
    exit 1
}

Write-Host "TOOL CONTRACT : VALID"

$authorizedWorkers = @($contract.authorized_workers)
$allowedActions = @($contract.allowed_actions)

if ($authorizedWorkers -notcontains $WorkerId) {
    Write-Host "WORKER AUTHORIZATION : DENIED"
    exit 1
}

Write-Host "WORKER AUTHORIZATION : VALID"

if ($allowedActions -notcontains $Action.ToUpperInvariant()) {
    Write-Host "ACTION AUTHORIZATION : DENIED"
    exit 1
}

Write-Host "ACTION AUTHORIZATION : VALID"

if ($contract.client_isolation -ne $true) {
    Write-Host "CLIENT ISOLATION : ERROR"
    exit 1
}

if ($contract.project_isolation -ne $true) {
    Write-Host "PROJECT ISOLATION : ERROR"
    exit 1
}

if ($contract.worker_isolation -ne $true) {
    Write-Host "WORKER ISOLATION : ERROR"
    exit 1
}

if ($contract.financial_action -ne $false) {
    Write-Host "FINANCIAL TOOL ACTION : BLOCKED"
    exit 1
}

Write-Host "CLIENT ISOLATION : VALID"
Write-Host "PROJECT ISOLATION: VALID"
Write-Host "WORKER ISOLATION  : VALID"
Write-Host "FINANCE           : BLOCKED"

if ($contract.external_action -eq $true) {
    Write-Host "EXTERNAL TOOL     : CONTROLLED"
}
else {
    Write-Host "EXTERNAL TOOL     : NOT REQUIRED"
}

if ($contract.secret_required -eq $true) {
    Write-Host "SECRET            : REQUIRED BY CONTRACT"
    Write-Host "SECRET VALUE      : NOT LOADED"
}
else {
    Write-Host "SECRET            : NOT REQUIRED"
}

$result = [ordered]@{
    status = "AUTHORIZED"
    worker_id = $WorkerId
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    tool_id = $ToolId
    action = $Action.ToUpperInvariant()
    external_action = $contract.external_action
    financial_action = $contract.financial_action
    secret_required = $contract.secret_required
    secret_loaded = $false
    client_isolation = $contract.client_isolation
    project_isolation = $contract.project_isolation
    worker_isolation = $contract.worker_isolation
    security_status = "VALID"
    execution = "NOT_EXECUTED"
    audit_logging = $contract.audit_logging
    human_override = $contract.human_override
    generated_at = (Get-Date).ToString("o")
}

$outputPath = Join-Path `
    $runtimeDir `
    "TOOL-ROUTE-$WorkerId-$TaskId.json"

$result |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " TOOL ROUTER RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "STATUS        : AUTHORIZED"
Write-Host "TOOL          : $ToolId"
Write-Host "ACTION        : $($Action.ToUpperInvariant())"
Write-Host "WORKER        : $WorkerId"
Write-Host "SECURITY      : VALID"
Write-Host "EXECUTION     : NOT_EXECUTED"
Write-Host "SECRET LOADED : NO"
Write-Host "FINANCE       : BLOCKED"
Write-Host ""

Write-Host "OUTPUT : $outputPath"
Write-Host ""
Write-Host "TOOL ROUTER : READY"