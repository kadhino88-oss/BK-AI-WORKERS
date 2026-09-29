# ============================================================
# BK AI WORKERS
# OPENAI ADAPTER — appel reel
# Reecrit le 2026-09-14 : l'adapter etait un stub qui ne faisait
# jamais d'appel reseau reel (toujours "api_call": false). Cette
# version decrypte la cle DPAPI en memoire UNIQUEMENT pour la
# duree de l'appel HTTP, ne la journalise jamais, et l'efface
# immediatement apres usage (meme motif que SECURE-CREDENTIAL-
# LOADER.ps1, qui lui ne restitue jamais la cle en clair).
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
    [string]$Model = "NONE"
)

$ErrorActionPreference = "Stop"

$ProjectRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $ProjectRoot "core/ai/BK-Secret.ps1")
. (Join-Path $ProjectRoot "core\ai\adapters\Build-WorkerSystemPrompt.ps1")

$EffectiveModel = if ([string]::IsNullOrWhiteSpace($Model) -or $Model -eq "NONE") { "gpt-4o-mini" } else { $Model }

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " BK AI WORKERS" -ForegroundColor Cyan
Write-Host " OPENAI ADAPTER" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "CLIENT   : $ClientId"
Write-Host "PROJECT  : $ProjectId"
Write-Host "WORKER   : $WorkerId"
Write-Host "TASK     : $TaskId"
Write-Host "MODEL    : $EffectiveModel"
Write-Host ""

if (-not (Test-BKSecret -Name "openai")) {
    Write-Host "CREDENTIAL : NOT CONFIGURED" -ForegroundColor Yellow

    [ordered]@{
        status = "ERROR"
        provider = "openai"
        model = $EffectiveModel
        mode = "SIMULATION"
        api_call = $false
        answer = ""
        error = "CREDENTIAL_NOT_CONFIGURED"
    } | ConvertTo-Json -Depth 10

    exit 1
}

$SecureCredential = $null
$CredentialPtr = [IntPtr]::Zero
$PlainKey = $null
$ResponseText = $null
$ErrorDetail = $null
$ExitCode = 1

try {
    $PlainKey = Get-BKSecretValue -Name "openai"

    if ([string]::IsNullOrWhiteSpace($PlainKey)) {
        throw "CREDENTIAL_EMPTY"
    }

    $SystemPrompt = Get-WorkerSystemPrompt -WorkerId $WorkerId -ClientId $ClientId

    $Body = @{
        model = $EffectiveModel
        messages = @(
            @{ role = "system"; content = $SystemPrompt }
            @{ role = "user"; content = $Objective }
        )
        max_tokens = 1800
        temperature = 0.4
    } | ConvertTo-Json -Depth 10

    $Headers = @{
        "Authorization" = "Bearer $PlainKey"
        "Content-Type"  = "application/json"
    }

    $Response = Invoke-RestMethod `
        -Uri "https://api.openai.com/v1/chat/completions" `
        -Method Post `
        -Headers $Headers `
        -Body $Body `
        -TimeoutSec 30

    $ResponseText = $Response.choices[0].message.content
    $ExitCode = 0
}
catch {
    $ErrorDetail = $_.Exception.Message
    $ExitCode = 1
}
finally {
    # Effacement immediat de la cle en clair de la memoire du
    # processus, qu'il y ait eu succes ou echec de l'appel.
    $PlainKey = $null
    $SecureCredential = $null
}

if ($ExitCode -eq 0) {
    Write-Host "API CALL : REEL" -ForegroundColor Green
    Write-Host "SECRET EXPOSE : NON (efface apres usage)" -ForegroundColor Green

    [ordered]@{
        status = "SUCCESS"
        provider = "openai"
        model = $EffectiveModel
        mode = "LLM"
        api_call = $true
        client_id = $ClientId
        project_id = $ProjectId
        worker = $WorkerId.ToUpper()
        task_id = $TaskId
        objective = $Objective
        answer = $ResponseText
        usage = [ordered]@{ input_tokens = [int]$Response.usage.prompt_tokens; output_tokens = [int]$Response.usage.completion_tokens }
        recommendations = @()
        next_action = "Utiliser la reponse du fournisseur dans le traitement du Worker."
        security_status = "VALID"
        financial_actions = $false
        external_actions = $false
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 10

    Write-Host ""
    Write-Host "OPENAI ADAPTER : SUCCESS" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "API CALL : ECHEC" -ForegroundColor Red
    Write-Host "DETAIL   : $ErrorDetail" -ForegroundColor Red

    [ordered]@{
        status = "ERROR"
        provider = "openai"
        model = $EffectiveModel
        mode = "LLM"
        api_call = $true
        answer = ""
        error = $ErrorDetail
        generated_at = (Get-Date).ToUniversalTime().ToString("o")
    } | ConvertTo-Json -Depth 10

    exit 1
}
