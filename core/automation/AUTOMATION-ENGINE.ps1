# =====================================================================
# BK-AI-WORKERS — Moteur d'automatisation (missions recurrentes)
# Persiste des automatisations (Worker + objectif + frequence) et les
# execute en reutilisant le VRAI pipeline existant (dashboard/Submit-Task.ps1
# -> Invoke-Orchestrator/Invoke-Worker-AI/Invoke-Chloe-Orchestration),
# donc aucune nouvelle surface de securite : meme gate d'autonomie,
# meme mode SIMULATION, memes traces dans runtime/tasks/.
# Ecrit le 2026-09-15.
# =====================================================================

$Script:AutomationRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
$Script:AutomationDataDir = Join-Path $Script:AutomationRoot "core/automation/data"
$Script:AutomationStorePath = Join-Path $Script:AutomationDataDir "automations.json"
$Script:AutomationRunsDir = Join-Path $Script:AutomationDataDir "runs"
$Script:SubmitTaskPath = Join-Path $Script:AutomationRoot "dashboard/Submit-Task.ps1"

# Verrou inter-processus + ecriture atomique de automations.json (fichier
# commun a toutes les missions/clients, incident du 2026-09-28).
. (Join-Path $Script:AutomationRoot "core/runtime/State-Lock.ps1")
. (Join-Path $Script:AutomationRoot "core/integrations/Slack-Adapter.ps1")

function Initialize-AutomationStore {
    if (-not (Test-Path -LiteralPath $Script:AutomationDataDir -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:AutomationDataDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Script:AutomationRunsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $Script:AutomationRunsDir -Force | Out-Null
    }
    if (-not (Test-Path -LiteralPath $Script:AutomationStorePath -PathType Leaf)) {
        # Re-verifie SOUS verrou : une autre mission a pu creer (et deja
        # remplir) le fichier entre le test ci-dessus et l'ecriture.
        Invoke-BKStateLocked {
            if (-not (Test-Path -LiteralPath $Script:AutomationStorePath -PathType Leaf)) {
                Write-BKStateFileAtomic -Path $Script:AutomationStorePath -Content "[]"
            }
        } | Out-Null
    }
}

function Get-Automations {
    <#
    -ClientId filtre la liste a UN client (chaque client ne doit jamais
    voir les automatisations d'un autre, meme cloisonnement que la
    facturation/le profil/l'activite). Les automatisations creees avant
    le 2026-09-22 (isolation par client) n'ont pas de champ clientId :
    on les traite comme appartenant a Kader (CLI-DASHBOARD), le seul
    utilisateur qui pouvait en creer a l'epoque.
    #>
    param([string]$ClientId = "")
    Initialize-AutomationStore
    $Raw = Get-Content -LiteralPath $Script:AutomationStorePath -Raw
    if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
    $Parsed = $Raw | ConvertFrom-Json
    if ($null -eq $Parsed) { return @() }
    $All = @($Parsed)
    if ([string]::IsNullOrWhiteSpace($ClientId)) { return $All }
    return @($All | Where-Object { (Get-AutomationClientId $_) -eq $ClientId })
}

function Get-AutomationClientId {
    param($Automation)
    if ($Automation.PSObject.Properties.Name -contains "clientId" -and $Automation.clientId) {
        return $Automation.clientId
    }
    return "CLI-DASHBOARD"
}

function Save-Automations {
    <#
    ConvertTo-Json "deballe" un tableau d'un seul element (comportement
    PowerShell 5.1/7 connu, deja contourne dans Automation-Bridge.ps1 pour
    sa propre sortie) : sans ce garde-fou explicite, automations.json
    devient un objet JSON nu des qu'il ne reste plus qu'une seule
    automatisation, ce qu'un lecteur qui attend un tableau (dont le
    tableau de bord Python, qui lit ce fichier directement pour les
    analytics) ne sait pas parser.
    #>
    param([Parameter(Mandatory=$true)][AllowEmptyCollection()][array]$Automations)
    Initialize-AutomationStore
    $Count = $Automations.Count
    $Json = if ($Count -eq 0) {
        "[]"
    } elseif ($Count -eq 1) {
        "[" + (@($Automations)[0] | ConvertTo-Json -Depth 10) + "]"
    } else {
        $Automations | ConvertTo-Json -Depth 10
    }
    Write-BKStateFileAtomic -Path $Script:AutomationStorePath -Content $Json
}

function New-Automation {
    param(
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [Parameter(Mandatory=$true)][string]$Objective,
        [Parameter(Mandatory=$true)][int]$FrequencyMinutes,
        [bool]$Enabled = $true,
        [bool]$NotifySlack = $false,
        [string]$ClientId = "CLI-DASHBOARD"
    )

    # Lecture -> ajout -> ecriture dans le MEME bloc verrouille ; le bloc
    # renvoie $New (seule sortie), que la fonction renvoie tel quel.
    return (Invoke-BKStateLocked {
        $Automations = @(Get-Automations)
        $Now = [DateTime]::UtcNow

        $New = [ordered]@{
            id               = "AUTO-" + [guid]::NewGuid().ToString("N").Substring(0,10).ToUpperInvariant()
            clientId         = $ClientId
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
        $New
    })
}

function Remove-AutomationById {
    <#
    -ClientId, s'il est fourni, restreint la suppression a UNE
    automatisation appartenant reellement a ce client — un client ne
    doit jamais pouvoir supprimer celle d'un autre en devinant son id.
    #>
    param([Parameter(Mandatory=$true)][string]$Id, [string]$ClientId = "")
    # Les "return" ci-dessous sortent du BLOC verrouille ; la fonction
    # renvoie exactement la valeur ($true/$false) produite par le bloc.
    return (Invoke-BKStateLocked {
        $Automations = @(Get-Automations)
        $Target = $Automations | Where-Object { $_.id -eq $Id }
        if (-not $Target) { return $false }
        if ($ClientId -and (Get-AutomationClientId $Target) -ne $ClientId) { return $false }
        $Automations = @($Automations | Where-Object { $_.id -ne $Id })
        Save-Automations -Automations $Automations
        return $true
    })
}

function Set-AutomationEnabled {
    <#
    -ClientId, s'il est fourni, restreint l'action a UNE automatisation
    appartenant reellement a ce client (meme raison que Remove-AutomationById).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [Parameter(Mandatory=$true)][bool]$Enabled,
        [string]$ClientId = ""
    )
    Invoke-BKStateLocked {
        $Automations = @(Get-Automations)
        foreach ($A in $Automations) {
            if ($A.id -eq $Id -and (-not $ClientId -or (Get-AutomationClientId $A) -eq $ClientId)) {
                $A.enabled = $Enabled
            }
        }
        Save-Automations -Automations $Automations
    } | Out-Null
}

function Invoke-AutomationRun {
    <#
    Execute UNE automatisation immediatement (bouton "Executer maintenant"
    ou tick arrive a echeance), en passant par le vrai pipeline
    dashboard/Submit-Task.ps1 (identite/session/token + gate d'autonomie
    + dispatch Worker ou Chloe + trace runtime/tasks/).
    #>
    param(
        [Parameter(Mandatory=$true)]$Automation,
        # Passage AUTOMATIQUE (cron ou tick) et non clic sur "Executer maintenant" : seul un passage automatique est coupe par la pause de
        # l'installation du Worker (interrupteur d'arret, voir dashboard/installations.py) ; une mission lancee a la main reste possible.
        [switch]$Scheduled
    )

    Initialize-AutomationStore
    $AllowedWorkersEnv = $null

    # -----------------------------------------------------------------
    # Garde-fou quota (correctif securite).
    # Le controle de quota subscription_blocks_mission ne vivait QUE dans
    # les endpoints HTTP de dashboard/server.py. Les automatisations
    # declenchees par cron (deploy/tick-automations.sh -> Automation-Bridge.ps1
    # -Action tick -> Invoke-AutomationTick -> Invoke-AutomationRun ->
    # Submit-Task.ps1) ne passent par AUCUN de ces endpoints : un client au
    # quota epuise voyait quand meme ses automatisations recurrentes
    # s'executer. On reutilise ici EXACTEMENT la meme regle (via le pont
    # Python dashboard/quota-check.py, qui importe server.py — aucune
    # duplication de la logique de facturation) AVANT de soumettre la tache.
    # Tout echec du verificateur est fail-open (quota indicatif, aucun PSP
    # branche) : on n'interrompt jamais une automatisation a cause d'un bug
    # du check — le helper echoue deja open, on double-protege ici.
    try {
        $QuotaClientId = Get-AutomationClientId $Automation
        $QuotaScript = Join-Path $Script:AutomationRoot "dashboard/quota-check.py"
        $PyCmd = if ($env:BK_PYTHON) { $env:BK_PYTHON } else { "python3" }
        if (Test-Path -LiteralPath $QuotaScript -PathType Leaf) {
            $QuotaMode = if ($Scheduled) { "scheduled" } else { "manual" }
            $QuotaLine = & $PyCmd $QuotaScript $QuotaClientId ([string]$Automation.workerId) $QuotaMode 2>$null | Select-Object -Last 1
            if ($QuotaLine) {
                $QuotaVerdict = $QuotaLine | ConvertFrom-Json
                if (-not $QuotaVerdict.blocked -and $QuotaVerdict.PSObject.Properties.Name -contains "allowedWorkers" -and $QuotaVerdict.allowedWorkers) {
                    # Offre "Worker a l'unite" : liste des Workers embauches, relue par Submit-Task.ps1 et Chloe (BK_ALLOWED_WORKERS).
                    $AllowedWorkersEnv = [string]$QuotaVerdict.allowedWorkers
                }
                if ($QuotaVerdict.blocked) {
                    $SkipStatus = switch ([string]$QuotaVerdict.code) {
                        "WORKER_NOT_INCLUDED" { "worker_not_included" }
                        "INSTALLATION_PAUSED" { "installation_paused" }
                        default { "quota_exceeded" }
                    }
                    # Quota epuise : on NE soumet PAS la tache. On trace le
                    # saut avec le MEME mecanisme de persistance qu'un run
                    # normal (meme forme de RunRecord + meme dossier runs/<id>/,
                    # lu par Get-AutomationRuns), au statut quota_exceeded, on
                    # avance l'echeance comme un passage normal, puis on
                    # retourne tot un objet de la meme forme que le retour
                    # habituel (le pont lira $RunResult.status = "quota_exceeded").
                    $SkipRecord = [ordered]@{
                        automationId = $Automation.id
                        ranAtUtc     = [DateTime]::UtcNow.ToString("o")
                        status       = $SkipStatus
                        detail       = $QuotaVerdict.detail
                    }
                    $SkipDir = Join-Path $Script:AutomationRunsDir $Automation.id
                    if (-not (Test-Path -LiteralPath $SkipDir -PathType Container)) {
                        New-Item -ItemType Directory -Path $SkipDir -Force | Out-Null
                    }
                    $SkipFile = Join-Path $SkipDir ("run-" + [DateTime]::UtcNow.ToString("yyyyMMdd-HHmmss") + ".json")
                    ($SkipRecord | ConvertTo-Json -Depth 20) | Set-Content -LiteralPath $SkipFile -Encoding UTF8

                    Invoke-BKStateLocked {
                        $Automations = @(Get-Automations)
                        foreach ($A in $Automations) {
                            if ($A.id -eq $Automation.id) {
                                $A.lastRunAtUtc  = $SkipRecord.ranAtUtc
                                $A.lastRunStatus = $SkipStatus
                                $A.nextRunAtUtc  = [DateTime]::UtcNow.AddMinutes($A.frequencyMinutes).ToString("o")
                                $A.runCount      = [int]$A.runCount + 1
                            }
                        }
                        Save-Automations -Automations $Automations
                    } | Out-Null

                    return $SkipRecord
                }
            }
        }
    }
    catch {
        # Fail-open : toute defaillance du verificateur de quota (python
        # absent, import impossible, JSON invalide...) ne doit JAMAIS faire
        # echouer l'automatisation — le quota est indicatif. On laisse
        # passer et on execute normalement.
        Write-Verbose "Verification de quota ignoree (echec non bloquant) : $($_.Exception.Message)"
    }

    $OutFile = Join-Path $Script:AutomationRunsDir ("tmp-" + [guid]::NewGuid().ToString("N") + ".json")

    function QuoteArg([string]$Value) {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    $OnLinux = ($PSVersionTable.PSEdition -eq "Core") -and ($IsWindows -eq $false)
    $PsExe = if ($OnLinux) { "pwsh" } else { "powershell" }
    # @(...) autour du if/else est obligatoire : un if/else qui "retourne"
    # un tableau a un seul element (cas Linux, juste "-NoProfile") est
    # deballe en simple chaine par le pipeline PowerShell si on ne force
    # pas explicitement le type tableau sur le resultat global — sans ce
    # garde-fou, "$PolicyArgs + @(...)" concatene la chaine directement
    # au premier element suivant ("-NoProfile-File", sans espace ni
    # separation d'arguments) et Submit-Task.ps1 ne recoit jamais un
    # -File valide : chaque automatisation echoue silencieusement en
    # NO_OUTPUT sous Linux/Docker (bug reel trouve le 2026-09-22 en
    # testant les automatisations en libre-service sur la prod).
    $PolicyArgs = @(if ($OnLinux) { "-NoProfile" } else { "-NoProfile", "-ExecutionPolicy", "Bypass" })
    $ArgLine = ($PolicyArgs + @(
        "-File", (QuoteArg $Script:SubmitTaskPath),
        "-Request", (QuoteArg $Automation.objective),
        "-WorkerId", (QuoteArg $Automation.workerId),
        "-ClientId", (QuoteArg (Get-AutomationClientId $Automation)),
        "-OutFile", (QuoteArg $OutFile)
    )) -join " "

    $Status = "ERROR"
    $Detail = $null
    $StdOutFile = [System.IO.Path]::GetTempFileName()
    $StdErrFile = [System.IO.Path]::GetTempFileName()
    # Le sous-processus herite de l'environnement : on lui transmet la liste des Workers embauches (offre "Worker a l'unite"), ou on retire
    # toute valeur heritee quand le client a acces a tous les Workers. L'ancienne valeur est restauree apres l'appel.
    $PreviousAllowedWorkers = $env:BK_ALLOWED_WORKERS
    if ($AllowedWorkersEnv) { $env:BK_ALLOWED_WORKERS = $AllowedWorkersEnv } else { Remove-Item Env:BK_ALLOWED_WORKERS -ErrorAction SilentlyContinue }
    try {
        $Proc = Start-Process -FilePath $PsExe -ArgumentList $ArgLine -NoNewWindow -Wait -PassThru `
            -RedirectStandardOutput $StdOutFile `
            -RedirectStandardError $StdErrFile

        if (Test-Path -LiteralPath $OutFile -PathType Leaf) {
            $Result = Get-Content -LiteralPath $OutFile -Raw | ConvertFrom-Json
            $Status = if ($Result.Status) { $Result.Status } else { "UNKNOWN" }
            $Detail = $Result
        } else {
            # Pas de fichier de sortie : le sous-processus a echoue avant
            # meme d'ecrire -OutFile. On recupere stdout/stderr (sinon
            # silencieusement perdus) pour que "NO_OUTPUT" reste
            # diagnosticable au lieu d'une boite noire.
            $Status = "NO_OUTPUT"
            $CapturedErr = (Get-Content -LiteralPath $StdErrFile -Raw -ErrorAction SilentlyContinue)
            $CapturedOut = (Get-Content -LiteralPath $StdOutFile -Raw -ErrorAction SilentlyContinue)
            $Detail = ($CapturedErr, $CapturedOut | Where-Object { $_ }) -join " | "
        }
    }
    catch {
        $Status = "EXCEPTION"
        $Detail = $_.Exception.Message
    }
    finally {
        if ($null -ne $PreviousAllowedWorkers) { $env:BK_ALLOWED_WORKERS = $PreviousAllowedWorkers } else { Remove-Item Env:BK_ALLOWED_WORKERS -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $OutFile -PathType Leaf) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $StdOutFile -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $StdErrFile -Force -ErrorAction SilentlyContinue
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
    $AutomationClientId = Get-AutomationClientId $Automation
    if ($Automation.notifySlack -and (Test-SlackConfigured -ClientId $AutomationClientId)) {
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

        $null = Send-SlackMessage -ClientId $AutomationClientId -Text $SlackText -WorkerName "BK-AI-WORKERS Automatisations"
    }

    # Met a jour l'automatisation (dernier passage + prochaine echeance)
    # Relecture -> modification -> ecriture sous verrou, APRES le
    # sous-processus et l'appel Slack (jamais de processus/reseau dans le
    # bloc) : une autre mission a pu modifier automations.json entre-temps.
    Invoke-BKStateLocked {
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
    } | Out-Null

    return $RunRecord
}

function Invoke-AutomationTick {
    <#
    Parcourt les automatisations activees dont l'echeance est passee et
    les execute. A appeler soit manuellement (bouton dashboard), soit via
    une tache planifiee Windows reelle si Kader valide cette option
    (creation de configuration persistante = demande explicitement).
    -ClientId, s'il est fourni, ne traite QUE les automatisations de ce
    client (le tick declenche par un client depuis le dashboard ne doit
    jamais executer celles d'un autre).
    #>
    param([string]$ClientId = "")
    $Automations = @(Get-Automations -ClientId $ClientId | Where-Object { $_.enabled -eq $true })
    $Now = [DateTime]::UtcNow
    $Ran = @()

    foreach ($A in $Automations) {
        $NextRun = [DateTime]::Parse($A.nextRunAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($NextRun -le $Now) {
            $Result = Invoke-AutomationRun -Automation $A -Scheduled
            $Ran += [pscustomobject]@{ AutomationId = $A.id; Status = $Result.status }
        }
    }

    return $Ran
}

function Get-AutomationRuns {
    <#
    -ClientId, s'il est fourni, verifie que l'automatisation appartient
    bien a ce client avant de renvoyer son historique — sinon un client
    pourrait lire l'historique d'un autre en devinant son id.
    #>
    param([Parameter(Mandatory=$true)][string]$Id, [int]$Limit = 10, [string]$ClientId = "")
    if ($ClientId) {
        $Owner = @(Get-Automations) | Where-Object { $_.id -eq $Id }
        if (-not $Owner -or (Get-AutomationClientId $Owner) -ne $ClientId) { return @() }
    }
    $RunDir = Join-Path $Script:AutomationRunsDir $Id
    if (-not (Test-Path -LiteralPath $RunDir -PathType Container)) { return @() }
    $Files = Get-ChildItem -LiteralPath $RunDir -Filter "run-*.json" | Sort-Object Name -Descending | Select-Object -First $Limit
    return @($Files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw | ConvertFrom-Json })
}
