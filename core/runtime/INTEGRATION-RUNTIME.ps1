# BK AI WORKERS
# INTEGRATION RUNTIME
# PHASE 7H-8
# CONTROLLED TOOL EXECUTION

param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({
        $RegistryPath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\worker-runtime\WORKER-REGISTRY.json"
        $Registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
        $ValidIds = $Registry.workers.PSObject.Properties.Name | ForEach-Object { $_.ToUpperInvariant() }
        if ($ValidIds -contains $_.ToUpperInvariant()) { return $true }
        throw "WorkerId '$_' absent de WORKER-REGISTRY.json (valeurs valides : $($ValidIds -join ', '))"
    })]
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
    [string]$Action,

    [Parameter(Mandatory=$false)]
    [ValidateSet("SIMULATION","LIVE")]
    [string]$Mode = "SIMULATION"
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$routerPath = Join-Path $projectRoot "core\tools\TOOL-ROUTER.ps1"
$runtimeDir = Join-Path $projectRoot "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " INTEGRATION RUNTIME"
Write-Host " PHASE 7H-8"
Write-Host "============================================"
Write-Host ""

Write-Host "WORKER : $WorkerId"
Write-Host "CLIENT : $ClientId"
Write-Host "PROJECT: $ProjectId"
Write-Host "TASK   : $TaskId"
Write-Host "TOOL   : $ToolId"
Write-Host "ACTION : $Action"
Write-Host "MODE   : $Mode"
Write-Host ""

if (!(Test-Path -LiteralPath $routerPath)) {
    Write-Host "TOOL ROUTER : NOT FOUND"
    exit 1
}

Write-Host "TOOL ROUTER : PRESENT"

Write-Host ""
Write-Host "============================================"
Write-Host " STEP 1 - AUTHORIZATION"
Write-Host "============================================"
Write-Host ""

powershell.exe -NoProfile -ExecutionPolicy Bypass -File `
    $routerPath `
    -WorkerId $WorkerId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -TaskId $TaskId `
    -ToolId $ToolId `
    -Action $Action

if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "TOOL AUTHORIZATION : DENIED"
    exit 1
}

$routePath = Join-Path `
    $runtimeDir `
    "TOOL-ROUTE-$WorkerId-$TaskId.json"

if (!(Test-Path -LiteralPath $routePath)) {
    Write-Host "ROUTE RESULT : NOT FOUND"
    exit 1
}

try {
    $route = Get-Content -LiteralPath $routePath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "ROUTE RESULT : INVALID"
    exit 1
}

if ($route.status -ne "AUTHORIZED") {
    Write-Host "ROUTE STATUS : INVALID"
    exit 1
}

if ($route.worker_id -ne $WorkerId) {
    Write-Host "WORKER IDENTITY : INVALID"
    exit 1
}

if ($route.client_id -ne $ClientId) {
    Write-Host "CLIENT IDENTITY : INVALID"
    exit 1
}

if ($route.project_id -ne $ProjectId) {
    Write-Host "PROJECT IDENTITY : INVALID"
    exit 1
}

if ($route.task_id -ne $TaskId) {
    Write-Host "TASK IDENTITY : INVALID"
    exit 1
}

if ($route.financial_action -ne $false) {
    Write-Host "FINANCE : BLOCKED"
    exit 1
}

if ($route.security_status -ne "VALID") {
    Write-Host "SECURITY : INVALID"
    exit 1
}

Write-Host "AUTHORIZATION : VALID"
Write-Host "IDENTITY      : VALID"
Write-Host "SECURITY      : VALID"
Write-Host "FINANCE       : BLOCKED"

Write-Host ""
Write-Host "============================================"
Write-Host " STEP 2 - INTEGRATION"
Write-Host "============================================"
Write-Host ""

if ($Mode -eq "LIVE") {

    if ($route.external_action -eq $true) {
        Write-Host "LIVE EXTERNAL ACTION : BLOCKED"
        Write-Host "REASON : LIVE integrations not yet activated"
        exit 1
    }

    Write-Host "LIVE MODE : NO EXTERNAL EXECUTION"
}

Write-Host "INTEGRATION : $ToolId"
Write-Host "ACTION      : $($Action.ToUpperInvariant())"
Write-Host "MODE        : $Mode"

if ($route.secret_required -eq $true) {
    Write-Host "SECRET      : REQUIRED"
    Write-Host "SECRET LOAD : BLOCKED IN SIMULATION"
}
else {
    Write-Host "SECRET      : NOT REQUIRED"
}

Write-Host ""
Write-Host "EXECUTION : SIMULATED"

$result = [ordered]@{
    status = "SUCCESS"
    mode = $Mode
    worker_id = $WorkerId
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    tool_id = $ToolId
    action = $Action.ToUpperInvariant()
    authorization = "VALID"
    execution = "SIMULATED"
    secret_required = $route.secret_required
    secret_loaded = $false
    external_action = $route.external_action
    financial_action = $route.financial_action
    security_status = "VALID"
    result = "Simulation d'exécution de l'intégration $ToolId."
    generated_at = (Get-Date).ToString("o")
}

$outputPath = Join-Path `
    $runtimeDir `
    "INTEGRATION-$WorkerId-$TaskId.json"

$result |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " INTEGRATION RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "STATUS        : SUCCESS"
Write-Host "WORKER        : $WorkerId"
Write-Host "TOOL          : $ToolId"
Write-Host "ACTION        : $($Action.ToUpperInvariant())"
Write-Host "MODE          : $Mode"
Write-Host "EXECUTION     : SIMULATED"
Write-Host "AUTHORIZATION : VALID"
Write-Host "SECURITY      : VALID"
Write-Host "SECRET LOADED : NO"
Write-Host "FINANCE       : BLOCKED"
Write-Host ""

Write-Host "OUTPUT : $outputPath"
Write-Host ""
Write-Host "INTEGRATION RUNTIME : READY"