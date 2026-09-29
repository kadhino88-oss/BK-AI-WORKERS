param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$Objective
)

$ErrorActionPreference = "Stop"

$RuntimeDirectory = Join-Path $PSScriptRoot "runtime"

if (-not (Test-Path -LiteralPath $RuntimeDirectory)) {
    New-Item -ItemType Directory -Path $RuntimeDirectory -Force | Out-Null
}

$Timestamp = Get-Date -Format "yyyyMMdd-HHmmss-fff"

$ContextId = "CTX-$Timestamp"

$TaskId = "TASK-$Timestamp"

$Context = [ordered]@{
    context_id = $ContextId
    client_id = $ClientId
    project_id = $ProjectId
    worker_id = $WorkerId
    task_id = $TaskId
    objective = $Objective

    scope = [ordered]@{
        client = $true
        project = $true
        worker = $true
    }

    permissions = [ordered]@{
        read = $true
        write = $true
        external_actions = $false
        financial_actions = $false
    }

    memory = [ordered]@{
        global = @()
        client = @()
        project = @()
        worker = @()
        task = @()
    }

    created_at = (Get-Date).ToString("o")
    updated_at = (Get-Date).ToString("o")
}

$FileName = "$ContextId.json"

$ContextPath = Join-Path $RuntimeDirectory $FileName

$Json = $Context | ConvertTo-Json -Depth 20

Set-Content `
    -LiteralPath $ContextPath `
    -Value $Json `
    -Encoding UTF8

if (-not (Test-Path -LiteralPath $ContextPath)) {
    Write-Host ""
    Write-Host "ERREUR : le contexte n'a pas été créé." -ForegroundColor Red
    exit 1
}

try {
    Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json | Out-Null
}
catch {
    Write-Host ""
    Write-Host "ERREUR : le JSON du contexte est invalide." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " CONTEXT ENGINE - SIMULATION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "CONTEXT ID : $ContextId"
Write-Host "CLIENT     : $ClientId"
Write-Host "PROJECT    : $ProjectId"
Write-Host "WORKER     : $WorkerId"
Write-Host "TASK       : $TaskId"
Write-Host ""

Write-Host "READ       : AUTHORIZED" -ForegroundColor Green
Write-Host "WRITE      : AUTHORIZED" -ForegroundColor Green
Write-Host "EXTERNAL   : BLOCKED" -ForegroundColor Yellow
Write-Host "FINANCE    : BLOCKED" -ForegroundColor Yellow
Write-Host ""

Write-Host "CONTEXTE CREE :" -ForegroundColor Green
Write-Host $ContextPath
Write-Host ""

Write-Host "JSON       : VALID" -ForegroundColor Green
Write-Host "STATUS     : READY" -ForegroundColor Green
Write-Host ""