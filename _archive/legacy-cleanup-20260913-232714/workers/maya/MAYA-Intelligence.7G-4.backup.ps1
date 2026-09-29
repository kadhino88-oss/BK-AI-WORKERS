# ============================================================
# BK AI WORKERS
# MAYA - INTELLIGENCE ENGINE
# PHASE 7D-7
# AI GATEWAY INTEGRATION
# ============================================================

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

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Gateway = Join-Path $Root "core\ai\AI-GATEWAY.ps1"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MAYA INTELLIGENCE ENGINE"
Write-Host " PHASE 7D-7"
Write-Host " AI GATEWAY INTEGRATION"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host ""

# ============================================================
# 1. IDENTITE
# ============================================================

if ($WorkerId.ToUpper() -ne "MAYA") {
    Write-Host "WORKER : INVALID" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $Gateway)) {
    Write-Host "AI GATEWAY : NOT FOUND" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $ContextPath)) {
    Write-Host "CONTEXT : NOT FOUND" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $MemoryPath)) {
    Write-Host "MEMORY : NOT FOUND" -ForegroundColor Red
    exit 1
}

# ============================================================
# 2. CONTEXTE
# ============================================================

$Context = Get-Content -Raw -Path $ContextPath | ConvertFrom-Json

if ($Context.client_id -and $Context.client_id -ne $ClientId) {
    Write-Host "CLIENT ISOLATION : INVALID" -ForegroundColor Red
    exit 1
}

if ($Context.project_id -and $Context.project_id -ne $ProjectId) {
    Write-Host "PROJECT ISOLATION : INVALID" -ForegroundColor Red
    exit 1
}

if ($Context.worker_id -and $Context.worker_id.ToUpper() -ne "MAYA") {
    Write-Host "WORKER ISOLATION : INVALID" -ForegroundColor Red
    exit 1
}

Write-Host "CONTEXT : VALID" -ForegroundColor Green

# ============================================================
# 3. SECURITE
# ============================================================

$FinanceBlocked = $true
$ExternalBlocked = $true

if ($Context.permissions) {
    if ($Context.permissions.financial_actions -eq $true) {
        Write-Host "FINANCE : BLOCKED" -ForegroundColor Yellow
    }
}

Write-Host "FINANCE : BLOCKED" -ForegroundColor Yellow
Write-Host "EXTERNAL: BLOCKED" -ForegroundColor Yellow
Write-Host "SECURITY: VALID" -ForegroundColor Green

# ============================================================
# 4. MEMOIRE
# ============================================================

$Memory = Get-Content -Raw -Path $MemoryPath | ConvertFrom-Json

Write-Host ""
Write-Host "MEMORY : LOADED" -ForegroundColor Green

# ============================================================
# 5. AI GATEWAY
# ============================================================

Write-Host ""
Write-Host "============================================"
Write-Host " AI GATEWAY"
Write-Host "============================================"
Write-Host ""

Write-Host "AI GATEWAY : CONNECTING..." -ForegroundColor Cyan

& $Gateway `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -WorkerId "MAYA" `
    -TaskId $TaskId `
    -Objective $Request `
    -ContextPath $ContextPath `
    -MemoryPath $MemoryPath

if ($LASTEXITCODE -ne 0) {
    Write-Host "AI GATEWAY : FAILED" -ForegroundColor Red
    exit 1
}

Write-Host "AI GATEWAY : SUCCESS" -ForegroundColor Green

# ============================================================
# 6. RECUPERATION REPONSE GATEWAY
# ============================================================

$GatewayOutput = Join-Path $Root "memory\runtime\AI-GATEWAY-$TaskId.json"

if (-not (Test-Path $GatewayOutput)) {
    Write-Host "GATEWAY OUTPUT : NOT FOUND" -ForegroundColor Red
    exit 1
}

$GatewayResult = Get-Content -Raw -Path $GatewayOutput | ConvertFrom-Json

if ($GatewayResult.status -ne "SUCCESS") {
    Write-Host "GATEWAY STATUS : $($GatewayResult.status)" -ForegroundColor Red
    exit 1
}

# ============================================================
# 7. RESULTAT MAYA
# ============================================================

Write-Host ""
Write-Host "============================================"
Write-Host " MAYA RESULT"
Write-Host "============================================"
Write-Host ""

$MayaOutput = [ordered]@{
    status = "SUCCESS"
    mode = "AI_GATEWAY_LOCAL"
    worker = "MAYA"
    task_id = $TaskId
    client_id = $ClientId
    project_id = $ProjectId
    request = $Request

    gateway = [ordered]@{
        status = $GatewayResult.status
        mode = $GatewayResult.mode
        security_status = $GatewayResult.security_status
        financial_actions = $GatewayResult.financial_actions
        external_actions = $GatewayResult.external_actions
    }

    analysis = [ordered]@{
        objective = $Request
        source = "BK-AI-GATEWAY"
        intelligence_mode = "LOCAL"
    }

    recommendations = @(
        "Analyser la demande marketing.",
        "Definir le positionnement et la cible.",
        "Preparer les actions d'acquisition.",
        "Coordonner ALEX, EMMA, LEA et LUCAS si necessaire."
    )

    next_action = "Produire la strategie marketing detaillee avec le moteur IA."

    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}

$OutputPath = Join-Path $Root "memory\runtime\MAYA-$TaskId.json"

$MayaOutput |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $OutputPath -Encoding UTF8

Write-Host "STATUS : SUCCESS" -ForegroundColor Green
Write-Host "MODE   : AI_GATEWAY_LOCAL"
Write-Host ""
Write-Host "DELIVERABLE :"
Write-Host $OutputPath
Write-Host ""
Write-Host "MAYA : READY" -ForegroundColor Green
Write-Host ""