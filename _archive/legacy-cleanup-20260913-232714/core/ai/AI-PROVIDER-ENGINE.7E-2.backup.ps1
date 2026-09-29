# ============================================================
# BK AI WORKERS
# AI PROVIDER ENGINE
# PHASE 7E-2
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
$RuntimeDir = Join-Path $Root "memory\runtime"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " BK AI WORKERS" -ForegroundColor Cyan
Write-Host " AI PROVIDER ENGINE" -ForegroundColor Cyan
Write-Host " PHASE 7E-2" -ForegroundColor Cyan
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
    Write-Host "CONFIG : NOT FOUND" -ForegroundColor Red
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

if ($validWorkers -notcontains $WorkerId.ToUpper()) {
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
# 3. SECURITE
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

if ($config.security.secret_exposure -ne $false) {
    Write-Host "SECRET SECURITY : INVALID" -ForegroundColor Red
    exit 1
}

Write-Host "ISOLATION : VALID" -ForegroundColor Green
Write-Host "SECURITY  : VALID" -ForegroundColor Green

# ============================================================
# 4. FINANCE / EXTERNAL
# ============================================================

if ($config.security.financial_actions -ne $false) {
    Write-Host "FINANCE : BLOCKED" -ForegroundColor Yellow
    exit 1
}

if ($config.security.external_actions -ne $false) {
    Write-Host "EXTERNAL : BLOCKED" -ForegroundColor Yellow
    exit 1
}

Write-Host "FINANCE  : BLOCKED" -ForegroundColor Yellow
Write-Host "EXTERNAL : BLOCKED" -ForegroundColor Yellow

# ============================================================
# 5. PROVIDER SELECTION
# ============================================================

$normalizedProvider = $Provider.ToLower()

if ($normalizedProvider -eq "none" -or [string]::IsNullOrWhiteSpace($normalizedProvider)) {

    if ($config.active_provider -ne "NONE") {
        Write-Host "PROVIDER CONFIGURATION : INVALID" -ForegroundColor Red
        exit 1
    }

    $selectedProvider = "NONE"
    $selectedModel = "NONE"
    $mode = "LOCAL"

}
elseif ($normalizedProvider -eq "anthropic") {

    if ($config.providers.anthropic.enabled -ne $true) {
        Write-Host "ANTHROPIC : DISABLED" -ForegroundColor Yellow
        exit 1
    }

    $selectedProvider = "ANTHROPIC"
    $selectedModel = $Model
    $mode = "LLM"

}
elseif ($normalizedProvider -eq "openai") {

    if ($config.providers.openai.enabled -ne $true) {
        Write-Host "OPENAI : DISABLED" -ForegroundColor Yellow
        exit 1
    }

    $selectedProvider = "OPENAI"
    $selectedModel = $Model
    $mode = "LLM"

}
else {

    Write-Host "PROVIDER : UNSUPPORTED" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "PROVIDER SELECTION" -ForegroundColor Cyan
Write-Host "------------------"
Write-Host "SELECTED : $selectedProvider"
Write-Host "MODEL    : $selectedModel"
Write-Host "MODE     : $mode"

# ============================================================
# 6. CONTEXTE OPTIONNEL
# ============================================================

$contextLoaded = $false
$memoryLoaded = $false

if (-not [string]::IsNullOrWhiteSpace($ContextPath)) {

    if (-not (Test-Path $ContextPath)) {
        Write-Host "CONTEXT : NOT FOUND" -ForegroundColor Red
        exit 1
    }

    $context = Get-Content -Raw -Path $ContextPath | ConvertFrom-Json

    if ($context.client_id -and $context.client_id -ne $ClientId) {
        Write-Host "CONTEXT CLIENT : INVALID" -ForegroundColor Red
        exit 1
    }

    if ($context.project_id -and $context.project_id -ne $ProjectId) {
        Write-Host "CONTEXT PROJECT : INVALID" -ForegroundColor Red
        exit 1
    }

    if ($context.worker_id -and $context.worker_id.ToUpper() -ne $WorkerId.ToUpper()) {
        Write-Host "CONTEXT WORKER : INVALID" -ForegroundColor Red
        exit 1
    }

    $contextLoaded = $true
    Write-Host "CONTEXT : LOADED" -ForegroundColor Green
}

if (-not [string]::IsNullOrWhiteSpace($MemoryPath)) {

    if (-not (Test-Path $MemoryPath)) {
        Write-Host "MEMORY : NOT FOUND" -ForegroundColor Red
        exit 1
    }

    $memory = Get-Content -Raw -Path $MemoryPath | ConvertFrom-Json

    $memoryLoaded = $true
    Write-Host "MEMORY : LOADED" -ForegroundColor Green
}

# ============================================================
# 7. REPONSE NORMALISEE
# ============================================================

if ($mode -eq "LOCAL") {

    $answer = "Provider Engine local valide. Aucun fournisseur LLM externe n'est actif."

    $recommendations = @(
        "Le Gateway peut utiliser le Provider Engine.",
        "Le fournisseur actif reste NONE.",
        "Le mode LLM reste désactivé.",
        "La prochaine étape pourra connecter un fournisseur réel."
    )

    $nextAction = "Valider le Provider Engine avant activation d'un fournisseur LLM."

}
else {

    $answer = "Mode LLM sélectionné mais l'appel fournisseur n'est pas encore implémenté."

    $recommendations = @()

    $nextAction = "Implémenter le connecteur sécurisé du fournisseur."
}

# ============================================================
# 8. RESULTAT
# ============================================================

$result = [ordered]@{
    status = "SUCCESS"
    provider = $selectedProvider
    model = $selectedModel
    mode = $mode

    client_id = $ClientId
    project_id = $ProjectId
    worker = $WorkerId.ToUpper()
    task_id = $TaskId

    objective = $Objective

    context_loaded = $contextLoaded
    memory_loaded = $memoryLoaded

    answer = $answer
    recommendations = $recommendations
    next_action = $nextAction

    security_status = "VALID"
    financial_actions = $false
    external_actions = $false

    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}

$outputPath = Join-Path $RuntimeDir "PROVIDER-$TaskId.json"

$result |
    ConvertTo-Json -Depth 10 |
    Set-Content -Path $outputPath -Encoding UTF8

# ============================================================
# 9. FIN
# ============================================================

Write-Host ""
Write-Host "============================================" -ForegroundColor Green
Write-Host " PROVIDER ENGINE RESULT" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Green
Write-Host ""
Write-Host "STATUS   : SUCCESS" -ForegroundColor Green
Write-Host "PROVIDER : $selectedProvider"
Write-Host "MODEL    : $selectedModel"
Write-Host "MODE     : $mode"
Write-Host "SECURITY : VALID" -ForegroundColor Green
Write-Host "FINANCE  : BLOCKED" -ForegroundColor Yellow
Write-Host "EXTERNAL : BLOCKED" -ForegroundColor Yellow
Write-Host ""
Write-Host "OUTPUT : $outputPath"
Write-Host ""
Write-Host "PROVIDER ENGINE : READY" -ForegroundColor Green
Write-Host ""