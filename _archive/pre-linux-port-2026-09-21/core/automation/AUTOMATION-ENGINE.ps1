# =====================================================================
# BK-AI-WORKERS — Moteur d'automatisation (missions recurrentes)
# Persiste des automatisations (Worker + objectif + frequence) et les
# execute en reutilisant le VRAI pipeline existant (dashboard/Submit-Task.ps1
# -> Invoke-Orchestrator/Invoke-Worker-AI/Invoke-Chloe-Orchestration),
# donc aucune nouvelle surface de securite : meme gate d'autonomie,
# meme mode SIMULATION, memes traces dans runtime/tasks/.
# Ecrit le 2026-09-15.
# =====================================================================

$Script:AutomationRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Script:AutomationDataDir = Join-Path $Script:AutomationRoot "core\automation\data"
$Script:AutomationStorePath = Join-Path $Script:AutomationDataDir "automations.json"
$Script:AutomationRunsDir = Join-Path $Script:AutomationDataDir "runs"
$Script:SubmitTaskPath = Join-Path $Script:AutomationRoot "dashboard\Submit-Task.ps1"

. (Join-Path $Script:AutomationRoot "core\integrations\Slack-Adapter.ps1")

function Initialize-AutomationStore {
    if (-not (Test-Path -LiteralPath $Script:AutomationDataDir -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:AutomationDataDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Script:AutomationRunsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:AutomationRunsDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Script:AutomationStorePath -PathType Leaf)) {
        "[]" | Set-Content -LiteralPath $Script:AutomationStorePath -Encoding UTF8
    }
}

function Get-Automations {
    Initialize-AutomationStore
    $Raw = Get-Content -LiteralPath $Script:AutomationStorePath -Raw
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $Parsed = $Raw | ConvertFrom-Json
    if ($null -eq $Parsed) { return @() }
    return @($Parsed)
}

function Save-Automations {
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Automations)
    Initialize-AutomationStore
    $Json = if ($Automations.Count -eq 0) { "[]" } else { $Automations | ConvertTo-Json -Depth 10 }
    [System.IO.File]::WriteAllText($Script:AutomationStorePath, $Json, [System.Text.UTF8Encoding]::new($false))
}

function New-Automation {
    param(
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Objective,
        [Parameter(Mandatory=$true)][int]$FrequencyMinutes,
        [bool]$Enabled = $true,
        [bool]$NotifySlack = $false
    )

    $Automations = @(Get-Automations)
    $Now = [DateTime]::UtcNow

    $New = [ordered]@{
        id               = "AUTO-" + [guid]::NewGuid().ToString("N").Substring(0,10).ToUpperInvariant()
        workerId         = $WorkerId.ToLowerInvariant()
        objective        = $Objective
        frequencyMinutes = $FrequencyMinutes
        enabled          = $Enabled
        notifySlack      = $NotifySlack
        createdAtUtc     = $Now.ToString("o")
        lastRunAtUtc     = $null
        lastRunStatus    = $null
        nextRunAtUtc     = $Now.ToString("o")
        runCount         = 0
    }

    $Automations += [pscustomobject]$New
    Save-Automations -Automations $Automations
    return $New
}

function Remove-AutomationById {
    param([Parameter(Mandatory=$true)][string]$Id)
    $Automations = @(Get-Automations | Where-Object { $_.id -ne $Id })
    Save-Automations -Automations $Automations
}

function Set-AutomationEnabled {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][bool]$Enabled
    )
    $Automations = @(Get-Automations)
    foreach ($A in $Automations) {
        if ($A.id -eq $Id) { $A.enabled = $Enabled }
    }
    Save-Automations -Automations $Automations
}

function Invoke-AutomationRun {
    <#
    Execute UNE automatisation immediatement (bouton "Executer maintenant"
    ou tick arrive a echeance), en passant par le vrai pipeline
    dashboard/Submit-Task.ps1 (identite/session/token + gate d'autonomie
    + dispatch Worker ou Chloe + trace runtime/tasks/).
    #>
    param([Parameter(Mandatory=$true)]$Automation)

    Initialize-AutomationStore
    $OutFile = Join-Path $Script:AutomationRunsDir ("tmp-" + [guid]::NewGuid().ToString("N") + ".json")

    function QuoteArg([string]$Value) {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    $ArgLine = @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (QuoteArg $Script:SubmitTaskPath),
        "-Request", (QuoteArg $Automation.objective),
        "-WorkerId", (QuoteArg $Automation.workerId),
        "-OutFile", (QuoteArg $OutFile)
    ) -join " "

    $Status = "ERROR"
    $Detail = $null
    try {
        $Proc = Start-Process -FilePath "powershell" -ArgumentList $ArgLine -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput ([System.IO.Path]::GetTempFileName()) `
            -RedirectStandardError ([System.IO.Path]::GetTempFileName())

        if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
            $Result = Get-Content -LiteralPath $OutFile -Raw | ConvertFrom-Json
            $Status = if ($Result.Status) { $Result.Status } else { "UNKNOWN" }
            $Detail = $Result
        } else {
            $Status = "NO_OUTPUT"
        }
    }
    catch {
        $Status = "EXCEPTION"
        $Detail = $_.Exception.Message
    }
    finally {
        if (Test-Path -LiteralPath $OutFile -PathType Leaf) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
    }

    $RunRecord = [ordered]@{
        automationId = $Automation.id
        ranAtUtc     = [DateTime]::UtcNow.ToString("o")
        status       = $Status
        detail       = $Detail
    }
    $RunDir = Join-Path $Script:AutomationRunsDir $Automation.id
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) {
        New-Item -ItemType Directory -Path $RunDir -Force | Out-Null
    }
    $RunFile = Join-Path $RunDir ("run-" + [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss") + ".json")
    ($RunRecord | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $RunFile -Encoding UTF8

    # Notification Slack REELLE (si activee sur cette automatisation et
    # Slack configure) — resume la mission, pas de contenu arbitraire
    # invente : juste worker/objectif/statut/extrait de reponse reels.
    if ($Automation.notifySlack -and (Test-SlackConfigured)) {
        $AnswerExcerpt = $null
        if ($Detail) {
            if ($Detail.FinalSynthesis) { $AnswerExcerpt = $Detail.FinalSynthesis }
            elseif ($Detail.Result -and $Detail.Result.Answer) { $AnswerExcerpt = $Detail.Result.Answer }
        }
        if ($AnswerExcerpt -and $AnswerExcerpt.Length -gt 300) {
            $AnswerExcerpt = $AnswerExcerpt.Substring(0, 300) + "..."
        }

        $StatusIcon = if ($Status -eq "EXECUTED" -or $Status -eq "SUCCESS") { "✅" } else { "⚠️" }
        $SlackText = "$StatusIcon Automatisation *$($Automation.id)* ($($Automation.workerId)) — $Status`n" +
            "Objectif : $($Automation.objective)" +
            $(if ($AnswerExcerpt) { "`nRésultat : $AnswerExcerpt" } else { "" })

        $null = Send-SlackMessage -Text $SlackText -WorkerName "BK-AI-WORKERS Automatisations"
    }

    # Met a jour l'automatisation (dernier passage + prochaine echeance)
    $Automations = @(Get-Automations)
    foreach ($A in $Automations) {
        if ($A.id -eq $Automation.id) {
            $A.lastRunAtUtc  = $RunRecord.ranAtUtc
            $A.lastRunStatus = $Status
            $A.nextRunAtUtc  = [DateTime]::UtcNow.AddMinutes($A.frequencyMinutes).ToString("o")
            $A.runCount      = [int]$A.runCount + 1
        }
    }
    Save-Automations -Automations $Automations

    return $RunRecord
}

function Invoke-AutomationTick {
    <#
    Parcourt toutes les automatisations activees dont l'echeance est
    passee et les execute. A appeler soit manuellement (bouton dashboard),
    soit via une tache planifiee Windows reelle si Kader valide cette
    option (creation de configuration persistante = demande explicitement).
    #>
    $Automations = @(Get-Automations | Where-Object { $_.enabled -eq $true })
    $Now = [DateTime]::UtcNow
    $Ran = @()

    foreach ($A in $Automations) {
        $NextRun = [DateTime]::Parse($A.nextRunAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($NextRun -le $Now) {
            $Result = Invoke-AutomationRun -Automation $A
            $Ran += [pscustomobject]@{ AutomationId = $A.id; Status = $Result.status }
        }
    }

    return $Ran
}

function Get-AutomationRuns {
    param([Parameter(Mandatory=$true)][string]$Id, [int]$Limit = 10)
    $RunDir = Join-Path $Script:AutomationRunsDir $Id
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { return @() }
    $Files = Get-ChildItem -LiteralPath $RunDir -Filter "run-*.json" | Sort-Object Name -Descending | Select-Object -First $Limit
    return @($Files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
}
