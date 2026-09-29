# ============================================================
# BK AI WORKERS
# AI PROVIDER ENGINE
# PHASE 7E-4B
# ADAPTER INTEGRATION
# ============================================================

param(
    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$WorkerId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string]$Objective,

    [Parameter(Mandatory=$false)]
    [string]$Provider = "NONE",

    [Parameter(Mandatory=$false)]
    [string]$Model = "NONE",

    [Parameter(Mandatory=$false)]
    [string]$ContextPath = "",

    [Parameter(Mandatory=$false)]
    [string]$MemoryPath = ""
)

$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$ConfigPath = Join-Path $Root "core\ai\AI-PROVIDERS.json"
$AdapterDir = Join-Path $Root "core\ai\adapters"
$RuntimeDir = Join-Path $Root "memory\runtime"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " BK AI WORKERS" -ForegroundColor Cyan
Write-Host " AI PROVIDER ENGINE" -ForegroundColor Cyan
Write-Host " PHASE 7E-4B" -ForegroundColor Cyan
Write-Host " ADAPTER INTEGRATION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "CLIENT   : $ClientId"
Write-Host "PROJECT  : $ProjectId"
Write-Host "WORKER   : $WorkerId"
Write-Host "TASK     : $TaskId"
Write-Host "PROVIDER : $Provider"
Write-Host "MODEL    : $Model"
Write-Host ""

# ============================================================
# 1. CONFIGURATION
# ============================================================

if (-not (Test-Path $ConfigPath)) {
    Write-Host "PROVIDER CONFIG : NOT FOUND" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $AdapterDir)) {
    Write-Host "ADAPTER DIRECTORY : NOT FOUND" -ForegroundColor Red
    exit 1
}

$config = Get-Content -Raw -Path $ConfigPath | ConvertFrom-Json

# ============================================================
# 2. IDENTITE
# ============================================================

$validWorkers = @(
    "LEA",
    "NOAH",
    "ALEX",
    "MAYA",
    "LUCAS",
    "EMMA",
    "SAM",
    "ATLAS"
)

$normalizedWorker = $WorkerId.ToUpper()
$normalizedProvider = $Provider.ToUpper()

if ($validWorkers -notcontains $normalizedWorker) {
    Write-Host "WORKER : INVALID" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ClientId)) {
    Write-Host "CLIENT : INVALID" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($ProjectId)) {
    Write-Host "PROJECT : INVALID" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($TaskId)) {
    Write-Host "TASK : INVALID" -ForegroundColor Red
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Objective)) {
    Write-Host "OBJECTIVE : INVALID" -ForegroundColor Red
    exit 1
}

Write-Host "IDENTITY : VALID" -ForegroundColor Green

# ============================================================
# 3. SECURITY
# ============================================================

if ($config.security.client_isolation -ne $true) {
    Write-Host "CLIENT ISOLATION : INVALID" -ForegroundColor Red
    exit 1
}

if ($config.security.project_isolation -ne $true) {
    Write-Host "PROJECT ISOLATION : INVALID" -ForegroundColor Red
    exit 1
}

if ($config.security.worker_isolation -ne $true) {
    Write-Host "WORKER ISOLATION : INVALID" -ForegroundColor Red
    exit 1
}

if ($config.security.financial_actions -ne $false) {
    Write-Host "FINANCE : INVALID" -ForegroundColor Red
    exit 1
}

if ($config.security.external_actions -ne $false) {
    Write-Host "EXTERNAL : INVALID" -ForegroundColor Red
    exit 1
}

if ($config.security.secret_exposure -ne $false) {
    Write-Host "SECRET SECURITY : INVALID" -ForegroundColor Red
    exit 1
}

Write-Host "ISOLATION : VALID" -ForegroundColor Green
Write-Host "SECURITY  : VALID" -ForegroundColor Green
Write-Host "FINANCE   : BLOCKED" -ForegroundColor Yellow
Write-Host "EXTERNAL  : BLOCKED" -ForegroundColor Yellow

# ============================================================
# 4. CONTEXT
# ============================================================

$contextLoaded = $false
$memoryLoaded = $false

if (-not [string]::IsNullOrWhiteSpace($ContextPath)) {

    if (-not (Test-Path $ContextPath)) {
        Write-Host "CONTEXT : NOT FOUND" -ForegroundColor Red
        exit 1
    }

    $Context = Get-Content -Raw -Path $ContextPath | ConvertFrom-Json

    if ($Context.client_id -and $Context.client_id -ne $ClientId) {
        Write-Host "CONTEXT CLIENT : INVALID" -ForegroundColor Red
        exit 1
    }

    if ($Context.project_id -and $Context.project_id -ne $ProjectId) {
        Write-Host "CONTEXT PROJECT : INVALID" -ForegroundColor Red
        exit 1
    }

    if ($Context.worker_id -and $Context.worker_id.ToUpper() -ne $normalizedWorker) {
        Write-Host "CONTEXT WORKER : INVALID" -ForegroundColor Red
        exit 1
    }

    $contextLoaded = $true
    Write-Host "CONTEXT : LOADED" -ForegroundColor Green
}

# ============================================================
# 5. MEMORY
# ============================================================

if (-not [string]::IsNullOrWhiteSpace($MemoryPath)) {

    if (-not (Test-Path $MemoryPath)) {
        Write-Host "MEMORY : NOT FOUND" -ForegroundColor Red
        exit 1
    }

    $Memory = Get-Content -Raw -Path $MemoryPath | ConvertFrom-Json

    $memoryLoaded = $true
    Write-Host "MEMORY : LOADED" -ForegroundColor Green
}

# ============================================================
# 6. PROVIDER SELECTION
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " PROVIDER SELECTION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

switch ($normalizedProvider) {

    "NONE" {

        Write-Host "SELECTED : NONE"
        Write-Host "MODEL    : NONE"
        Write-Host "MODE     : LOCAL"

        $adapterUsed = "NONE"
        $adapterResult = $null
    }

    "ANTHROPIC" {

        $adapterPath = Join-Path $AdapterDir "ANTHROPIC-ADAPTER.ps1"

        if (-not (Test-Path $adapterPath)) {
            Write-Host "ANTHROPIC ADAPTER : NOT FOUND" -ForegroundColor Red
            exit 1
        }

        Write-Host "SELECTED : ANTHROPIC"
        Write-Host "MODEL    : $Model"
        Write-Host "MODE     : SIMULATION"
        Write-Host "ADAPTER  : READY" -ForegroundColor Green

        $adapterUsed = "ANTHROPIC"

        $adapterOutput = & $adapterPath `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -WorkerId $normalizedWorker `
            -TaskId $TaskId `
            -Objective $Objective `
            -Model $Model

        if ($LASTEXITCODE -ne 0) {
            Write-Host "ANTHROPIC ADAPTER : FAILED" -ForegroundColor Red
            exit 1
        }

        $jsonLines = $adapterOutput |
            Where-Object { $_ -match '^\s*\{' -or $_ -match '^\s*"' }

        $adapterJson = ($adapterOutput -join "`n")

        try {
            $adapterResult = $adapterJson | ConvertFrom-Json
        }
        catch {
            Write-Host "ANTHROPIC ADAPTER OUTPUT : INVALID JSON" -ForegroundColor Red
            exit 1
        }
    }

    "OPENAI" {

        $adapterPath = Join-Path $AdapterDir "OPENAI-ADAPTER.ps1"

        if (-not (Test-Path $adapterPath)) {
            Write-Host "OPENAI ADAPTER : NOT FOUND" -ForegroundColor Red
            exit 1
        }

        Write-Host "SELECTED : OPENAI"
        Write-Host "MODEL    : $Model"
        Write-Host "MODE     : SIMULATION"
        Write-Host "ADAPTER  : READY" -ForegroundColor Green

        $adapterUsed = "OPENAI"

        $adapterOutput = & $adapterPath `
            -ClientId $ClientId `
            -ProjectId $ProjectId `
            -WorkerId $normalizedWorker `
            -TaskId $TaskId `
            -Objective $Objective `
            -Model $Model

        if ($LASTEXITCODE -ne 0) {
            Write-Host "OPENAI ADAPTER : FAILED" -ForegroundColor Red
            exit 1
        }

        $adapterJson = ($adapterOutput -join "`n")

        try {
            $adapterResult = $adapterJson | ConvertFrom-Json
        }
        catch {
            Write-Host "OPENAI ADAPTER OUTPUT : INVALID JSON" -ForegroundColor Red
            exit 1
        }
    }

    default {

        Write-Host "PROVIDER : UNSUPPORTED" -ForegroundColor Red
        exit 1
    }
}

# ============================================================
# 7. NORMALISATION
# ============================================================

if ($normalizedProvider -eq "NONE") {

    $providerName = "NONE"
    $providerModel = "NONE"
    $mode = "LOCAL"

    $answer = "Provider Engine local valide. Aucun fournisseur LLM externe n'est actif."
    $recommendations = @()
    $nextAction = "Sélectionner un adaptateur LLM lorsque la configuration sera validée."
    $securityStatus = "VALID"
}

else {

    if ($null -eq $adapterResult) {
        Write-Host "ADAPTER RESULT : EMPTY" -ForegroundColor Red
        exit 1
    }

    if ($adapterResult.status -ne "SUCCESS") {
        Write-Host "ADAPTER STATUS : $($adapterResult.status)" -ForegroundColor Red
        exit 1
    }

    $providerName = $adapterResult.provider
    $providerModel = $adapterResult.model
    $mode = $adapterResult.mode

    $answer = $adapterResult.answer
    $recommendations = $adapterResult.recommendations
    $nextAction = $adapterResult.next_action
    $securityStatus = $adapterResult.security_status
}

# ============================================================
# 8. RESULTAT NORMALISE
# ============================================================

$result = [ordered]@{

    status = "SUCCESS"

    provider = $providerName
    model = $providerModel
    mode = $mode

    adapter = $adapterUsed

    client_id = $ClientId
    project_id = $ProjectId
    worker = $normalizedWorker
    task_id = $TaskId

    objective = $Objective

    context_loaded = $contextLoaded
    memory_loaded = $memoryLoaded

    answer = $answer
    recommendations = $recommendations
    next_action = $nextAction

    security_status = $securityStatus

    financial_actions = $false
    external_actions = $false

    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}

# ============================================================
# 9. ECRITURE
# ============================================================

if (-not (Test-Path $RuntimeDir)) {
    New-Item -ItemType Directory -Force -Path $RuntimeDir | Out-Null
}

$outputPath = Join-Path $RuntimeDir "PROVIDER-$TaskId.json"

$result |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $outputPath -Encoding UTF8

# ============================================================
# 10. RESULTAT FINAL
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " PROVIDER ENGINE RESULT" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""

Write-Host "STATUS   : SUCCESS" -ForegroundColor Green
Write-Host "PROVIDER : $providerName"
Write-Host "MODEL    : $providerModel"
Write-Host "MODE     : $mode"
Write-Host "ADAPTER  : $adapterUsed"
Write-Host "SECURITY : $securityStatus" -ForegroundColor Green
Write-Host "FINANCE  : BLOCKED" -ForegroundColor Yellow
Write-Host "EXTERNAL : BLOCKED" -ForegroundColor Yellow
Write-Host ""

Write-Host "OUTPUT : $outputPath"
Write-Host ""

Write-Host "PROVIDER ENGINE : READY" -ForegroundColor Green