# Faux Invoke-Worker-AI.ps1 pour les tests de la delegation de Chloe : aucun modele, aucun reseau, aucun secret.
# Configuration : STUB_CONFIG (JSON { "default": {...}, "workers": { "LEA": {...} } }), journal : STUB_LOG (JSONL), dossier : STUB_DIR.
#   answer       texte de la reponse ({worker}, {attempt} sont remplaces)             delay_ms    attente avant de repondre
#   throw        message : le script leve une exception (comme un refus du Gate)       status      statut du resultat (SUCCESS par defaut)
#   degraded     true : reponse locale de secours (Degraded)                           empty       true : reponse vide
#   files        [{ "name": "x.md", "text": "..." }] : ecrits dans runtime/task-files/<TaskId>/ et declares dans Files
#   actions      [{ "connectorId": "gmail", "operation": "DRAFT_MESSAGE" }] : connector_actions en attente + fichier PENDING-ACTION
#   attempts     [ {...}, {...} ] : comportement propre a chaque essai (1er, 2e...) ; le dernier est repete
param([string]$WorkerId, [string]$TaskId, [string]$Objective, [string]$TenantId, [string]$ClientId, [string]$ProjectId, [string]$ExecutionId,
      [string]$UserId, [string]$SessionId, [string]$TokenId, [string]$Token, [string]$Environment, [string]$Mode, [string]$Provider, [string]$Model)

function Add-StubLog($Entry) {
    $Line = (($Entry | ConvertTo-Json -Depth 6 -Compress) + "`n")
    for ($i = 0; $i -lt 20; $i++) {
        try { [System.IO.File]::AppendAllText($env:STUB_LOG, $Line, [System.Text.UTF8Encoding]::new($false)); return } catch { Start-Sleep -Milliseconds 40 }
    }
}
function Now-Ms { return [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

$Cfg = Get-Content -LiteralPath $env:STUB_CONFIG -Raw -Encoding UTF8 | ConvertFrom-Json
$Spec = $null
if ($Cfg.workers) { $P = $Cfg.workers.PSObject.Properties[$WorkerId]; if ($P) { $Spec = $P.Value } }
if ($null -eq $Spec) { $Spec = $Cfg.default }
$AttemptFile = Join-Path $env:STUB_DIR ("attempt-" + $WorkerId + ".txt")
$Attempt = 1
if (Test-Path -LiteralPath $AttemptFile) { $Attempt = [int](Get-Content -LiteralPath $AttemptFile -Raw) + 1 }
Set-Content -LiteralPath $AttemptFile -Value $Attempt
if ($Spec.attempts) { $List = @($Spec.attempts); $Spec = $List[[Math]::Min($Attempt, $List.Count) - 1] }

Add-StubLog ([ordered]@{ event = "start"; worker = $WorkerId; taskId = $TaskId; attempt = $Attempt; t = (Now-Ms); objective = $Objective; executionId = $ExecutionId; clientId = $ClientId; tokenSeen = [bool]$Token })
if ($Spec.delay_ms) { Start-Sleep -Milliseconds ([int]$Spec.delay_ms) }
if ($Spec.throw) { Add-StubLog ([ordered]@{ event = "end"; worker = $WorkerId; attempt = $Attempt; t = (Now-Ms); thrown = $true }); throw [string]$Spec.throw }

$Answer = if ($Spec.empty -eq $true) { "" } else { ([string]$Spec.answer -replace '\{worker\}', $WorkerId -replace '\{attempt\}', $Attempt) }
if (-not $Spec.answer -and $Spec.empty -ne $true) { $Answer = "Reponse de $WorkerId" }
$Files = @()
foreach ($F in @($Spec.files)) {
    if (-not $F) { continue }
    $Dir = Join-Path (Join-Path $env:BK_ROOT "runtime/task-files") $TaskId
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Dir $F.name), [string]$F.text, [System.Text.UTF8Encoding]::new($false))
    $Files += [ordered]@{ fileId = "file_x"; filename = [string]$F.name; mime = "text/plain"; sizeBytes = ([string]$F.text).Length; path = "$TaskId/$($F.name)" }
}
$Result = [ordered]@{
    Schema = "BK-AI-WORKER-AI-RESULT"; Success = $true; WorkerId = $WorkerId; TaskId = $TaskId
    Status = $(if ($Spec.status) { [string]$Spec.status } else { "SUCCESS" })
    Degraded = [bool]($Spec.degraded -eq $true); FallbackReason = $(if ($Spec.degraded -eq $true) { "provider unavailable (test)" } else { $null })
    Answer = $Answer; Files = @($Files)
}
if ($Spec.error) { $Result["Answer"] = ""; $Result["Error"] = [string]$Spec.error }
if ($Spec.financial_actions -eq $true) { $Result["financial_actions"] = $true }
$Actions = @()
foreach ($A in @($Spec.actions)) {
    if (-not $A) { continue }
    $Actions += [ordered]@{ connectorId = [string]$A.connectorId; operation = [string]$A.operation; status = "PENDING_CONFIRMATION"; executed = $false }
    $Pdir = Join-Path $env:BK_ROOT "memory/runtime"
    New-Item -ItemType Directory -Path $Pdir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $Pdir "PENDING-ACTION-$TaskId.json"), ((@{ taskId = $TaskId; clientId = $ClientId; workerId = $WorkerId; connectorId = $A.connectorId; operation = $A.operation; params = @{ To = "a@b.ch" }; reason = "test" }) | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
}
if ($Actions.Count -gt 0) { $Result["connector_actions"] = @($Actions) }
Add-StubLog ([ordered]@{ event = "end"; worker = $WorkerId; attempt = $Attempt; t = (Now-Ms) })
$Result | ConvertTo-Json -Depth 8 -Compress
