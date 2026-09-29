$ErrorActionPreference = "Stop"

$MemoryRoot = "C:\Users\FEUCOM\BK-AI-WORKERS\memory"
$RuntimeDirectory = Join-Path $MemoryRoot "runtime"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " MEMORY ISOLATION TEST - PHASE 5" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $RuntimeDirectory)) {
    Write-Host "ERREUR : dossier runtime introuvable." -ForegroundColor Red
    exit 1
}

$Files = @(Get-ChildItem -LiteralPath $RuntimeDirectory -Filter "CTX-*.json" -File)

if ($Files.Count -eq 0) {
    Write-Host "ERREUR : aucun contexte trouve." -ForegroundColor Red
    exit 1
}

Write-Host "Contextes detectes : $($Files.Count)"
Write-Host ""

$Contexts = @()

foreach ($File in $Files) {

    try {
        $Content = Get-Content -LiteralPath $File.FullName -Raw
        $Context = $Content | ConvertFrom-Json
        $Contexts += $Context
    }
    catch {
        Write-Host "ERREUR JSON : $($File.Name)" -ForegroundColor Red
        exit 1
    }
}

Write-Host "JSON : TOUS VALIDES" -ForegroundColor Green
Write-Host ""

foreach ($Context in $Contexts) {

    if ([string]::IsNullOrWhiteSpace([string]$Context.context_id)) {
        Write-Host "ERREUR : context_id manquant." -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace([string]$Context.client_id)) {
        Write-Host "ERREUR : client_id manquant." -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace([string]$Context.project_id)) {
        Write-Host "ERREUR : project_id manquant." -ForegroundColor Red
        exit 1
    }

    if ([string]::IsNullOrWhiteSpace([string]$Context.worker_id)) {
        Write-Host "ERREUR : worker_id manquant." -ForegroundColor Red
        exit 1
    }
}

Write-Host "IDENTITE : TOUS LES CONTEXTES SONT COMPLETS" -ForegroundColor Green
Write-Host ""

$ContextIds = @(
    $Contexts | ForEach-Object {
        $_.context_id
    }
)

$UniqueContextIds = @(
    $ContextIds | Select-Object -Unique
)

if ($ContextIds.Count -ne $UniqueContextIds.Count) {
    Write-Host "ERREUR : context_id duplique." -ForegroundColor Red
    exit 1
}

Write-Host "IDENTIFIANTS : UNIQUES" -ForegroundColor Green
Write-Host ""

$ClientProjectPairs = @(
    $Contexts | ForEach-Object {
        "$($_.client_id)|$($_.project_id)"
    }
)

$UniquePairs = @(
    $ClientProjectPairs | Select-Object -Unique
)

if ($ClientProjectPairs.Count -ne $UniquePairs.Count) {
    Write-Host "ATTENTION : plusieurs contextes utilisent le meme client/projet." -ForegroundColor Yellow
}
else {
    Write-Host "CLIENT / PROJET : UNIQUES" -ForegroundColor Green
}

Write-Host ""

$SecurityOK = $true

foreach ($Context in $Contexts) {

    if ($Context.permissions.external_actions -ne $false) {
        Write-Host "ERREUR : actions externes autorisees." -ForegroundColor Red
        $SecurityOK = $false
    }

    if ($Context.permissions.financial_actions -ne $false) {
        Write-Host "ERREUR : actions financieres autorisees." -ForegroundColor Red
        $SecurityOK = $false
    }
}

if (-not $SecurityOK) {
    exit 1
}

Write-Host "FRONTIERE FINANCIERE : BLOQUEE" -ForegroundColor Green
Write-Host "ACTIONS EXTERNES     : BLOQUEES" -ForegroundColor Green
Write-Host ""

Write-Host "CONTEXTES PRESENTS :" -ForegroundColor Yellow
Write-Host ""

foreach ($Context in $Contexts) {

    Write-Host "  $($Context.context_id)"
    Write-Host "  Client  : $($Context.client_id)"
    Write-Host "  Projet  : $($Context.project_id)"
    Write-Host "  Worker  : $($Context.worker_id)"
    Write-Host ""
}

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " ISOLATION TEST REUSSI" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "RESULTAT : MEMORY SAFE" -ForegroundColor Green
Write-Host ""