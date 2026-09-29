# ============================================================
# BK AI WORKERS
# ANTHROPIC ADAPTER — appel reel (API Messages, Claude)
# Remplace le stub (qui ne faisait jamais d'appel reseau). Meme
# principe que OPENAI-ADAPTER.ps1 : la cle DPAPI
# (.secrets\anthropic.secret.dpapi, stockee par Kader lui-meme via
# Store-Credential.ps1) est dechiffree en memoire UNIQUEMENT le temps
# de l'appel HTTP, jamais journalisee, effacee juste apres.
# ============================================================

param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$WorkerId,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Objective,
    [Parameter(Mandatory=$false)][string]$Model = "NONE"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $ProjectRoot "core/ai/BK-Secret.ps1")
. (Join-Path $ProjectRoot "core\ai\adapters\Build-WorkerSystemPrompt.ps1")

# Modele : celui demande, sinon celui de AI-PROVIDERS.json, sinon Haiku 4.5.
$EffectiveModel = $Model
if ([string]::IsNullOrWhiteSpace($EffectiveModel) -or $EffectiveModel -eq "NONE") {
    $EffectiveModel = "claude-haiku-4-5-20251001"
    try {
        $Cfg = Get-Content -LiteralPath (Join-Path $ProjectRoot "core\ai\AI-PROVIDERS.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Cfg.providers.anthropic.model) { $EffectiveModel = [string]$Cfg.providers.anthropic.model }
    } catch { }
}

Write-Host "ANTHROPIC ADAPTER | worker=$WorkerId | model=$EffectiveModel"

function Write-Result($Object) { $Object | ConvertTo-Json -Depth 10 -Compress }

if (-not (Test-BKSecret -Name "anthropic")) {
    Write-Result ([ordered]@{ status="ERROR"; provider="anthropic"; model=$EffectiveModel; mode="SIMULATION"; api_call=$false; answer=""; error="CREDENTIAL_NOT_CONFIGURED" })
    exit 1
}

$PlainKey = $null
$ResponseText = $null; $ErrorDetail = $null; $ExitCode = 1
try {
    $PlainKey = Get-BKSecretValue -Name "anthropic"
    if ([string]::IsNullOrWhiteSpace($PlainKey)) { throw "CREDENTIAL_EMPTY" }

    $Body = @{
        model      = $EffectiveModel
        max_tokens = 1800
        system     = (Get-WorkerSystemPrompt -WorkerId $WorkerId -ClientId $ClientId)
        messages   = @( @{ role = "user"; content = $Objective } )
    } | ConvertTo-Json -Depth 10

    $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
        -Headers @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" } `
        -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($Body)) -TimeoutSec 60

    $ResponseText = (@($Response.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n")
    $ExitCode = 0
}
catch {
    $ErrorDetail = $_.Exception.Message
    $ExitCode = 1
}
finally {
    $PlainKey = $null
}

if ($ExitCode -eq 0) {
    Write-Result ([ordered]@{
        status="SUCCESS"; provider="anthropic"; model=$EffectiveModel; mode="LLM"; api_call=$true
        client_id=$ClientId; project_id=$ProjectId; worker=$WorkerId.ToUpper(); task_id=$TaskId
        answer=$ResponseText; recommendations=@()
        usage=[ordered]@{ input_tokens=[int]$Response.usage.input_tokens; output_tokens=[int]$Response.usage.output_tokens }
        next_action="Utiliser la reponse du fournisseur dans le traitement du Worker."
        security_status="VALID"; financial_actions=$false; external_actions=$false
        generated_at=(Get-Date).ToUniversalTime().ToString("o")
    })
    exit 0
}
else {
    Write-Result ([ordered]@{ status="ERROR"; provider="anthropic"; model=$EffectiveModel; mode="LLM"; api_call=$true; answer=""; error=$ErrorDetail })
    exit 1
}
