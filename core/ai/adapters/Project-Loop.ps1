# =====================================================================
# BK-AI-WORKERS - Boucle d'UNE ETAPE DE PROJET (docs/AUTONOMY-ENGINE.md, sections 3.2 a 3.11).
#
# Invoke-BKProjectStepLoop est construite a partir des fonctions communes extraites de ANTHROPIC-ADAPTER.ps1 (Adapter-Common.ps1 :
# Build-ConnectorToolDefinition, Test-ReadOnlyOperation, Get-ResponseText, Get-CodeExecFileIds, Save-BKCodeExecFiles...) et du suivi de
# cout de Mission-Cost.ps1 (inchange). Differences avec la boucle d'une mission (voir le tableau 3.2) :
#   - la boucle se termine sur l'outil step_complete / step_blocked, ou sur l'echeance douce, le plafond de cout, le nombre de tours ;
#   - une ECRITURE de connecteur n'arrete rien : elle devient un article d'approbation (outil request_approval, Python) et la reponse
#     « QUEUED:APR-... » est rendue au modele, la boucle CONTINUE ; seuls les vrais brouillons pre-autorises par le client partent seuls ;
#   - l'identifiant de conteneur du bac a sable est renvoye a chaque requete DE L'ETAPE (jamais entre deux etapes) ;
#   - cache_control sur le dernier bloc du dernier message a chaque appel (BK_PROJECT_CONVO_CACHE=0 pour couper) ;
#   - cost.json est reecrit apres CHAQUE reponse : si le processus meurt, le cout deja engage est regle par le superviseur ;
#   - reessais avec attente croissante (2, 5, 15, 40 s, +-20 %, retry-after respecte), pause_turn, max_tokens, refus, contexte trop long ;
#   - detecteur d'appels identiques, rappel de budget a 20 %, finalisation forcee, rapport minimal ecrit par le lanceur si besoin ;
#   - AUCUN secret ecrit dans un fichier ou un journal : la cle reste en memoire, le journal ne contient pas de contenu client brut.
# Le lanceur (Project-StepRunner.ps1) lit input.json, appelle cette fonction et ecrit result.json.
# =====================================================================

$Script:BKProjectBackoffSec = @(2, 5, 15, 40)

function Write-BKStepLog {
    # Journal de l'etape (steps/<id>/<n>/runner.log) : jamais de cle, jamais de contenu client au-dela de 200 caracteres.
    param($In, [string]$Message)
    try {
        $Line = (Get-Date).ToUniversalTime().ToString("o") + " " + ($Message -replace '[\r\n]+', ' ')
        if ($Line.Length -gt 600) { $Line = $Line.Substring(0, 600) }
        $Dir = [string]$In.paths.stepDir
        if ($Dir) { [System.IO.File]::AppendAllText((Join-Path $Dir "runner.log"), $Line + "`n", [System.Text.UTF8Encoding]::new($false)) }
    } catch { }
}

function Write-BKJsonFile {
    # Ecriture atomique (fichier temporaire du meme dossier puis remplacement), UTF-8 sans BOM.
    param([string]$Path, $Object, [int]$Depth = 30)
    $Tmp = $Path + ".tmp-" + [guid]::NewGuid().ToString("N").Substring(0, 8)
    try {
        [System.IO.File]::WriteAllText($Tmp, ($Object | ConvertTo-Json -Depth $Depth), [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $Tmp -Destination $Path -Force
    } finally { if (Test-Path -LiteralPath $Tmp) { Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue } }
}

function Write-BKCostFile {
    param($In, $Cost, [int]$Iteration)
    try {
        Write-BKJsonFile -Path (Join-Path ([string]$In.paths.stepDir) "cost.json") -Depth 6 -Object ([ordered]@{
            updatedUtc = (Get-Date).ToUniversalTime().ToString("o"); model = [string]$In.model; iteration = $Iteration
            usage = (Get-BKCostUsageFields -Cost $Cost)
        })
    } catch { }
}

function ConvertTo-BKUtcDate {
    # Date UTC d'un champ de input.json. ConvertFrom-Json transforme deja « 2026-10-19T09:44:36Z » en DateTime : on ne repasse JAMAIS par
    # [string] (la culture et le fuseau de la machine decaleraient l'echeance). Une chaine sans fuseau est lue comme UTC.
    param($Value)
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [System.DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($Value, [System.DateTimeKind]::Utc) }
        return $Value.ToUniversalTime()
    }
    if ($Value -is [DateTimeOffset]) { return $Value.UtcDateTime }
    return [DateTimeOffset]::Parse([string]$Value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal).UtcDateTime
}

function Get-BKPythonCommand {
    if ($env:BK_PYTHON) { return [string]$env:BK_PYTHON }
    if ($IsWindows -or $PSVersionTable.PSEdition -ne "Core") { return "python" }
    return "python3"
}

function Invoke-BKProjectTool {
    # Appelle un outil Python (dashboard/project-tool.py) : JSON sur l'entree standard, JSON sur la sortie. Renvoie TOUJOURS une table :
    # @{ ok = $true ; result = <objet> } ou @{ ok = $false ; error = CODE ; detail = ... ; problems = ... }. Jamais d'exception vers la boucle.
    param([string]$Name, $ToolInput, $In, [string]$Root, [int]$TimeoutSec = 90, $Raw = $null)
    try {
        $Payload = if ($null -ne $Raw) { $Raw } else {
            [ordered]@{ projectDir = [string]$In.paths.projectDir; stepDir = [string]$In.paths.stepDir; stepId = [string]$In.stepId; kind = [string]$In.kind
                        worker = [string]$In.worker; input = $(if ($null -ne $ToolInput) { $ToolInput } else { @{} }) }
        }
        $Json = $Payload | ConvertTo-Json -Depth 40 -Compress
        $Psi = New-Object System.Diagnostics.ProcessStartInfo
        $Psi.FileName = Get-BKPythonCommand
        [void]$Psi.ArgumentList.Add((Join-Path $Root "dashboard/project-tool.py"))
        [void]$Psi.ArgumentList.Add($Name)
        $Psi.RedirectStandardInput = $true; $Psi.RedirectStandardOutput = $true; $Psi.RedirectStandardError = $true
        $Psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
        $Psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $Psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)
        $Psi.UseShellExecute = $false
        $Psi.WorkingDirectory = $Root
        $Psi.Environment["BK_ROOT"] = $Root
        $Psi.Environment["PYTHONIOENCODING"] = "utf-8"
        $Proc = [System.Diagnostics.Process]::Start($Psi)
        $ErrTask = $Proc.StandardError.ReadToEndAsync()
        $OutTask = $Proc.StandardOutput.ReadToEndAsync()
        $Proc.StandardInput.Write($Json)
        $Proc.StandardInput.Close()
        if (-not $Proc.WaitForExit($TimeoutSec * 1000)) {
            try { $Proc.Kill($true) } catch { }
            return @{ ok = $false; error = "TOOL_TIMEOUT"; detail = "L'outil $Name a depasse son delai." }
        }
        [void]$OutTask.Wait(5000)
        $OutText = ([string]$OutTask.Result).Trim()
        if ([string]::IsNullOrWhiteSpace($OutText)) { return @{ ok = $false; error = "TOOL_FAILED"; detail = "L'outil $Name n'a rien renvoye (code $($Proc.ExitCode))." } }
        $Last = ($OutText -split "`n" | Where-Object { $_.Trim().StartsWith("{") } | Select-Object -Last 1)
        $Obj = $Last | ConvertFrom-Json
        $Out = @{ ok = [bool]$Obj.ok }
        if ($Obj.ok) { $Out["result"] = $Obj.result }
        else {
            $Out["error"] = [string]$Obj.error; $Out["detail"] = [string]$Obj.detail
            if ($Obj.problems) { $Out["problems"] = @($Obj.problems) }
        }
        return $Out
    } catch {
        return @{ ok = $false; error = "TOOL_FAILED"; detail = "L'outil $Name a echoue ($($_.Exception.GetType().Name))." }
    }
}

# ---------------------------------------------------------------------
# Appel de l'API Messages avec reessais. Renvoie @{ ok ; response } ou @{ ok = $false ; kind = unavailable|bad_request|fatal ; status ; text ; retryAfterSec }.
# 429, 529, 5xx, coupure reseau : attente 2, 5, 15, 40 s (+-20 %, retry-after respecte), 4 reessais au plus. Les erreurs 400 sont rendues
# a l'appelant, qui sait quel repli tenter (outil, bêta, context_management...).
# ---------------------------------------------------------------------
function Invoke-BKMessagesCall {
    param($Body, $Headers, [int]$TimeoutSec, $In)
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 40 -Compress))
    $Scale = 1.0
    if ($env:BK_PROJECT_BACKOFF_SCALE -match '^\d+(\.\d+)?$') { $Scale = [double]$env:BK_PROJECT_BACKOFF_SCALE }
    $Attempt = 0
    while ($true) {
        try {
            $Resp = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post -Headers $Headers -ContentType "application/json; charset=utf-8" `
                -Body $Bytes -TimeoutSec $TimeoutSec
            return @{ ok = $true; response = $Resp }
        }
        catch {
            $Status = 0
            try { $Status = [int]$_.Exception.Response.StatusCode } catch { }
            $Text = ([string]$_.ErrorDetails.Message) + " " + ([string]$_.Exception.Message)
            $RetryAfter = $null
            try {
                $Vals = $null
                if ($_.Exception.Response.Headers.TryGetValues("retry-after", [ref]$Vals)) { $RetryAfter = [double](@($Vals)[0]) }
            } catch { }
            $Transient = ($Status -eq 429 -or $Status -eq 529 -or ($Status -ge 500 -and $Status -le 599) -or $Status -eq 0)
            if ($Status -eq 400 -or $Status -eq 413) { return @{ ok = $false; kind = "bad_request"; status = $Status; text = $Text } }
            if (-not $Transient) { return @{ ok = $false; kind = "fatal"; status = $Status; text = $Text } }
            if ($Attempt -ge 4) { return @{ ok = $false; kind = "unavailable"; status = $Status; text = $Text; retryAfterSec = $RetryAfter } }
            $Base = $Script:BKProjectBackoffSec[[Math]::Min($Attempt, 3)]
            $Wait = if ($null -ne $RetryAfter -and $RetryAfter -gt 0) { [Math]::Min(120.0, $RetryAfter) } else { $Base * (0.8 + 0.4 * (Get-Random -Minimum 0.0 -Maximum 1.0)) }
            Write-BKStepLog -In $In -Message "API indisponible (HTTP $Status) : nouvel essai dans $([Math]::Round($Wait, 1)) s ($($Attempt + 1)/4)"
            Start-Sleep -Milliseconds ([int]($Wait * 1000 * $Scale))
            $Attempt++
        }
    }
}

# ---------------------------------------------------------------------
# Fichiers : entree (Files API) et sortie (bac a sable -> espace de travail).
# ---------------------------------------------------------------------
function Send-BKStepInputFiles {
    # Envoie les fichiers choisis (inputFiles, 8 au plus, 20 Mo) par Files API et renvoie @{ Blocks ; Ids }. Les identifiants vont dans files-api.json
    # (nettoyage) et ne sont JAMAIS montres au client. Un echec d'envoi n'arrete pas l'etape : le fichier reste lisible par workspace_read.
    param($In, [string]$PlainKey, [bool]$HasCodeTool)
    $Blocks = @(); $Ids = @()
    $Files = @($In.inputFiles)
    if ($Files.Count -eq 0 -or $null -eq $Files[0]) { return @{ Blocks = @(); Ids = @() } }
    $Ws = [string]$In.paths.workspace
    foreach ($F in $Files) {
        try {
            $Rel = [string]$F.path
            if ($Rel -notmatch '^[A-Za-z0-9][A-Za-z0-9._/-]{0,178}$' -or $Rel -match '(^|/)\.\.?(/|$)') { continue }
            $Full = Join-Path $Ws $Rel
            if (-not (Test-Path -LiteralPath $Full -PathType Leaf)) { continue }
            $As = [string]$F.as
            if ($As -eq "container_upload" -and -not $HasCodeTool) { continue }
            $Hdr = @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" }
            $Up = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/files" -Method Post -Headers $Hdr -TimeoutSec 120 -Form @{ file = (Get-Item -LiteralPath $Full); expires_in_seconds = "7200" }
            $Id = [string]$Up.id
            if (-not $Id) { continue }
            $Ids += $Id
            switch ($As) {
                "document" { $Blocks += @{ type = "document"; source = @{ type = "file"; file_id = $Id } } }
                "image" { $Blocks += @{ type = "image"; source = @{ type = "file"; file_id = $Id } } }
                default { $Blocks += @{ type = "container_upload"; file_id = $Id } }
            }
        } catch { Write-BKStepLog -In $In -Message "envoi d'un fichier d'entree impossible ($($_.Exception.GetType().Name))" }
    }
    if ($Ids.Count -gt 0) { try { Write-BKJsonFile -Path (Join-Path ([string]$In.paths.stepDir) "files-api.json") -Depth 4 -Object ([ordered]@{ uploaded = @($Ids); produced = @() }) } catch { } }
    return @{ Blocks = @($Blocks); Ids = @($Ids) }
}

function Remove-BKStepUploads {
    param([string]$PlainKey, $Ids, $In)
    foreach ($Id in @($Ids)) {
        try { Invoke-RestMethod -Uri "https://api.anthropic.com/v1/files/$Id" -Method Delete -Headers @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" } -TimeoutSec 30 | Out-Null } catch { }
    }
    if (@($Ids).Count -gt 0) { try { Write-BKJsonFile -Path (Join-Path ([string]$In.paths.stepDir) "files-api.json") -Depth 4 -Object ([ordered]@{ uploaded = @(); produced = @() }) } catch { } }
}

function Import-BKSandboxFiles {
    # Fichiers produits par le bac a sable : telecharges (puis supprimes chez Anthropic par Save-BKCodeExecFiles), puis importes dans l'espace de
    # travail PAR LE CHEMIN SUR de Python (extension, taille, nombre, confinement). Un nom « a__b__c.png » est range en « a/b/c.png ».
    param($In, [string]$PlainKey, $FileIds, [string]$Root, $Imported, $ImportErrors)
    $Ids = @($FileIds | Where-Object { $_ } | Select-Object -Unique)
    if ($Ids.Count -eq 0) { return }
    $Dir = Join-Path ([string]$In.paths.stepDir) "downloads"
    try { Write-BKJsonFile -Path (Join-Path ([string]$In.paths.stepDir) "files-api.json") -Depth 4 -Object ([ordered]@{ uploaded = @(); produced = @($Ids) }) } catch { }
    $Saved = Save-BKCodeExecFiles -FileIds $Ids -PlainKey $PlainKey -DestDir $Dir -PathPrefix "downloads" -MaxFiles 10
    foreach ($C in @($Saved.Captured)) {
        $Res = Invoke-BKProjectTool -Name "import_file" -In $In -Root $Root -ToolInput @{ srcPath = (Join-Path $Dir ([string]$C.filename)); destName = [string]$C.filename }
        if ($Res.ok) { [void]$Imported.Add([ordered]@{ path = [string]$Res.result.path; bytes = [long]$Res.result.bytes }) }
        else { [void]$ImportErrors.Add([string]$C.filename + " : " + [string]$Res.error) }
    }
    foreach ($S in @($Saved.Skipped)) { [void]$ImportErrors.Add("$S : trop volumineux ou en trop grand nombre") }
    try { Write-BKJsonFile -Path (Join-Path ([string]$In.paths.stepDir) "files-api.json") -Depth 4 -Object ([ordered]@{ uploaded = @(); produced = @() }) } catch { }
}

# ---------------------------------------------------------------------
# Messages : cache de la conversation, resultats d'outils.
# ---------------------------------------------------------------------
function Set-BKConversationCache {
    # Un seul point d'arret de cache dans les messages : le dernier bloc du dernier message utilisateur (les precedents sont retires : 4 au plus
    # au total, dont celui du prompt systeme).
    param($Messages)
    foreach ($M in $Messages) {
        if ($M.content -is [System.Array] -or $M.content -is [System.Collections.IList]) {
            foreach ($B in $M.content) { if ($B -is [hashtable] -and $B.ContainsKey("cache_control")) { $B.Remove("cache_control") } }
        }
    }
    if ($Messages.Count -eq 0) { return }
    $Last = $Messages[$Messages.Count - 1]
    if ($Last.role -ne "user" -or -not ($Last.content -is [System.Array] -or $Last.content -is [System.Collections.IList]) -or $Last.content.Count -eq 0) { return }
    $Blk = $Last.content[$Last.content.Count - 1]
    if ($Blk -is [hashtable]) { $Blk["cache_control"] = @{ type = "ephemeral" } }
}

function New-BKToolResultBlock {
    param([string]$Id, $Content, [bool]$IsError = $false)
    $B = @{ type = "tool_result"; tool_use_id = $Id; content = $Content }
    if ($IsError) { $B["is_error"] = $true }
    return $B
}

function ConvertTo-BKToolText {
    # Resultat d'outil rendu au modele : JSON compact, borne (le contexte de la boucle ne doit pas exploser).
    param($Object, [int]$Max = 24000)
    $T = $Object | ConvertTo-Json -Depth 20 -Compress
    if ($T.Length -gt $Max) { $T = $T.Substring(0, $Max) + " ...[tronque]" }
    return $T
}

function New-BKMinimalReport {
    # Rapport ecrit par le lanceur quand le modele n'a pas pu conclure : fichiers modifies depuis le debut de l'etape + dernier texte.
    param($In, [datetime]$Since, [string]$LastText, [string]$Reason, $Imported)
    $Files = @()
    try {
        $Ws = [string]$In.paths.workspace
        $Files = @(Get-ChildItem -LiteralPath $Ws -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTimeUtc -ge $Since.AddSeconds(-1) -and -not $_.Name.StartsWith(".") } |
            Select-Object -First 15 | ForEach-Object { $_.FullName.Substring($Ws.TrimEnd('\', '/').Length + 1).Replace('\', '/') })
    } catch { }
    $Txt = ([string]$LastText).Trim()
    if ($Txt.Length -gt 1500) { $Txt = $Txt.Substring(0, 1500) }
    $Why = switch ($Reason) { "deadline" { "l'echeance de l'etape est atteinte" } "cost_ceiling" { "le plafond de cout de l'etape est atteint" } "iterations" { "le nombre de tours de l'etape est atteint" } default { "l'etape s'est arretee avant de conclure" } }
    $Summary = "Etape interrompue ($Why)." + $(if ($Files.Count -gt 0) { " Fichiers ecrits ou modifies : " + ($Files -join ", ") + "." } else { " Aucun fichier n'a ete ecrit." }) + $(if ($Txt) { " Dernier message : " + $Txt } else { "" })
    return [ordered]@{ status = "PARTIAL"; summary = $Summary; deliverables = @(); criteriaClaims = @(); remaining = @("Poursuivre l'etape : relire workspace/ et terminer le travail"); summaryUpdate = ""; decisions = @()
                       inputQuestions = @(); nextSuggestions = @(); handoffNote = ""; ignoredInstructions = @() }
}

function New-BKStepResult {
    param([string]$Status, [string]$ExitReason, $Report = $null, [string]$AnswerText = "", $Cost, $In, [datetime]$Started, [int]$Iterations = 0, $Imported = $null, $Err = $null, $RetryAfter = $null)
    return [ordered]@{
        schema = "BK-STEP-RESULT-V1"; status = $Status; exitReason = $ExitReason
        report = $(if ($null -ne $Report) { $Report } else { [ordered]@{} }); answerText = $AnswerText
        usage = (Get-BKCostUsageFields -Cost $Cost); model = [string]$In.model; iterations = $Iterations
        filesImported = @($Imported); error = $Err; retryAfterSec = $RetryAfter
        startedUtc = $Started.ToUniversalTime().ToString("o"); finishedUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
}

function Get-BKOtherModel {
    param([string]$Model)
    if ($Model -like "claude-opus*") { return "claude-sonnet-5-5" }
    return "claude-opus-5-5"
}

# ---------------------------------------------------------------------
# Execution d'UN tool_use cote client. Renvoie @{ Content ; IsError ; End ; Report ; Mutated }.
# ---------------------------------------------------------------------
function Invoke-BKStepToolUse {
    param($ToolUse, $In, [string]$Root, $State)
    $Name = [string]$ToolUse.name
    $ToolIn = $ToolUse.input
    $Allowed = @($In.tools)
    if ($Name -ne "memory" -and $Name -ne "use_connector" -and $Name -notin $Allowed) {
        return @{ Content = "Outil indisponible dans cette etape : $Name."; IsError = $true; End = $null; Report = $null; Mutated = $false }
    }

    if ($Name -eq "memory") {
        if ([string]$ToolIn.action -eq "write") {
            $State.MemoryWrites++
            if ($State.MemoryWrites -gt 6) { return @{ Content = "Limite atteinte : 6 ecritures de memoire au plus par etape."; IsError = $true; End = $null; Report = $null; Mutated = $false } }
        }
        $MemOut = Invoke-BKMemoryTool -Root $Root -ClientId ([string]$In.clientId) -ToolInput $ToolIn
        return @{ Content = [string]$MemOut; IsError = $false; End = $null; Report = $null; Mutated = $false }
    }

    if ($Name -eq "use_connector") { return Invoke-BKStepConnector -ToolUse $ToolUse -In $In -Root $Root -State $State }

    $Res = Invoke-BKProjectTool -Name $Name -ToolInput $ToolIn -In $In -Root $Root
    if ($Name -eq "step_complete") {
        if ($Res.ok -and $Res.result.accepted) {
            return @{ Content = "Rapport d'etape accepte."; IsError = $false; End = "complete"; Report = $Res.result.report; Mutated = $false }
        }
        $State.ReportRejections++
        return @{ Content = (ConvertTo-BKToolText $Res); IsError = $true; End = $null; Report = $null; Mutated = $false }
    }
    if ($Name -eq "step_blocked") {
        if ($Res.ok -and $Res.result.accepted) {
            return @{ Content = "Blocage enregistre."; IsError = $false; End = "blocked"; Report = $Res.result.blocked; Mutated = $false }
        }
        return @{ Content = (ConvertTo-BKToolText $Res); IsError = $true; End = $null; Report = $null; Mutated = $false }
    }
    if (-not $Res.ok) { return @{ Content = (ConvertTo-BKToolText $Res); IsError = $true; End = $null; Report = $null; Mutated = $false } }
    $Mut = $Name -in @("workspace_write", "workspace_append", "workspace_delete", "deliverable_register", "request_approval", "request_input", "project_plan", "note_decision") -or $Name -like "site_*"
    if ($Name -eq "workspace_view_image" -and $Res.result.base64) {
        $Img = @(@{ type = "image"; source = @{ type = "base64"; media_type = [string]$Res.result.mediaType; data = [string]$Res.result.base64 } }, @{ type = "text"; text = "Image : " + [string]$Res.result.path })
        return @{ Content = $Img; IsError = $false; End = $null; Report = $null; Mutated = $false }
    }
    return @{ Content = (ConvertTo-BKToolText $Res.result); IsError = $false; End = $null; Report = $null; Mutated = $Mut }
}

function Invoke-BKStepConnector {
    # use_connector. Lecture : executee tout de suite. Ecriture : article d'approbation (Python valide connecteur, operation, parametres, risque, doublon,
    # plafonds) ; « QUEUED:APR-... » est rendu au modele et la boucle CONTINUE. Seuls les vrais brouillons pre-autorises par le client partent seuls.
    param($ToolUse, $In, [string]$Root, $State)
    $ConnId = [string]$ToolUse.input.connectorId
    $Op = [string]$ToolUse.input.operation
    $Reason = [string]$ToolUse.input.reason
    $OpParams = @{}
    if ($ToolUse.input.params) { $ToolUse.input.params.PSObject.Properties | ForEach-Object { $OpParams[$_.Name] = $_.Value } }
    $Active = @(Get-ClientActivatedConnectors -ClientId ([string]$In.clientId))
    if ($ConnId -notin $Active) { return @{ Content = "Le connecteur « $ConnId » n'est pas connecte a ce compte : termine avec step_blocked (raison CONNECTOR) si tu en as besoin."; IsError = $true; End = $null; Report = $null; Mutated = $false } }
    if (Test-ReadOnlyOperation -Operation $Op) {
        $ActionResult = Invoke-ConnectorAction -ConnectorId "$ConnId.controlled" -Operation $Op -ClientId ([string]$In.clientId) -Params $OpParams
        return @{ Content = (ConvertTo-BKToolText $ActionResult 16000); IsError = $false; End = $null; Report = $null; Mutated = $false }
    }
    # Ecriture : pre-autorisation du client seulement pour un vrai brouillon, installation non en pause, jamais une sortie d'argent du compte proprietaire.
    $IsFinancial = (Get-ConnectorBaseId -ConnectorId "$ConnId.controlled") -in @("stripe", "paypal", "quickbooks", "xero")
    $Auto = ([bool]$In.autoApproveSafeOps) -and -not [bool]$In.installationPaused -and (("$ConnId|$Op") -in $AutoApproveSafeOps) -and -not ($In.clientId -eq "CLI-DASHBOARD" -and $IsFinancial)
    if ($Auto) {
        $ActionResult = Invoke-ConnectorAction -ConnectorId "$ConnId.controlled" -Operation $Op -ClientId ([string]$In.clientId) -Params $OpParams
        $null = Invoke-BKProjectTool -Name "record_executed_action" -In $In -Root $Root -ToolInput @{ connectorId = $ConnId; operation = $Op; params = $OpParams; title = "$ConnId : $Op"; why = $Reason
            execution = @{ connectorStatus = [string]$ActionResult.Status; detail = [string]$ActionResult.Detail } }
        return @{ Content = ((ConvertTo-BKToolText $ActionResult 4000) + " (brouillon enregistre automatiquement, comme le client l'a autorise)"); IsError = $false; End = $null; Report = $null; Mutated = $true }
    }
    $Req = @{ kind = "connector"; title = "$ConnId : $Op"; connectorId = $ConnId; operation = $Op; params = $OpParams; why = $Reason }
    if ($ToolUse.input.title) { $Req["title"] = [string]$ToolUse.input.title }
    $Res = Invoke-BKProjectTool -Name "request_approval" -ToolInput $Req -In $In -Root $Root
    if ($Res.ok) { return @{ Content = [string]$Res.result.note; IsError = $false; End = $null; Report = $null; Mutated = $true } }
    return @{ Content = (ConvertTo-BKToolText $Res); IsError = $true; End = $null; Report = $null; Mutated = $false }
}

# ---------------------------------------------------------------------
# LA BOUCLE
# ---------------------------------------------------------------------
function Invoke-BKProjectStepLoop {
    param($In, [string]$PlainKey, [string]$Root)
    $Started = (Get-Date).ToUniversalTime()
    $Kind = [string]$In.kind
    $Soft = ConvertTo-BKUtcDate $In.deadlineUtc
    $Hard = ConvertTo-BKUtcDate $In.hardDeadlineUtc
    $SoftTotalSec = [Math]::Max(30.0, ($Soft - $Started).TotalSeconds)
    $MaxIterations = [Math]::Max(1, [int]$In.maxIterations)
    $CallTimeout = [Math]::Max(30, [int]$In.callTimeoutSec)
    $Model = [string]$In.model
    $UseEffort = ($In.effort -and $Model -notlike "claude-haiku-4*")
    $WebMax = [int]$In.webMaxUses
    $Cost = New-BKMissionCost -Pricing (Get-BKPricing -Root $Root) -Model $Model -CeilingChf $In.ceilingChf
    $State = @{ MemoryWrites = 0; ReportRejections = 0 }
    $Imported = [System.Collections.ArrayList]@()
    $ImportErrors = [System.Collections.ArrayList]@()
    $MaxTokens = switch ($Kind) { "answer" { 4000 } { $_ -in @("plan", "replan", "verify") } { 16000 } default { 32000 } }

    # ---- prompt systeme : identite du Worker (ou controleur neutre) + addendum + guide de la sorte d'etape + recette
    if ($In.language) { $env:BK_REPLY_LANG = [string]$In.language }
    $Base = if ($Kind -eq "verify") { Get-BKProjectVerifierIdentity -In $In } else { Get-WorkerSystemPrompt -WorkerId ([string]$In.worker) -ClientId ([string]$In.clientId) }
    $Soft0 = [int][Math]::Round($SoftTotalSec)
    $System = [string]$Base + (Get-BKProjectAddendum -In $In -SoftSeconds $Soft0 -Kind $Kind) + (Get-BKProjectKindGuide -Kind $Kind -In $In)
    if (-not [string]::IsNullOrWhiteSpace([string]$In.recipeBlock)) { $System += "`n`nRECETTE (un guide, pas un carcan : adapte-la et dis pourquoi) :`n" + [string]$In.recipeBlock }
    if (@("plan", "replan") -contains $Kind -and [string]$In.worker -eq "chloe") {
        $PlanMd = Join-Path $Root "chloe/prompts/plan.md"
        if ((Test-Path -LiteralPath $PlanMd -PathType Leaf) -and (Get-Item -LiteralPath $PlanMd).Length -lt 20000) { $System += "`n`nREGLES DE PLANIFICATION DE CHLOE :`n" + (Get-Content -LiteralPath $PlanMd -Raw -Encoding UTF8) }
    }
    $SystemBlocks = @(@{ type = "text"; text = $System; cache_control = @{ type = "ephemeral" } })

    # ---- outils : serveur (web, code), puis cote client dans un ordre stable (le cache du prefixe en depend)
    $Defs = Get-BKProjectToolDefinitions
    $ClientTools = @()
    $Missing = @()
    foreach ($T in @($In.tools)) {
        if ($T -eq "use_connector") { $CD = Build-ConnectorToolDefinition -ClientId ([string]$In.clientId); if ($CD) { $ClientTools += $CD }; continue }
        if ($T -eq "memory") { if (Get-BKMemoryDir -Root $Root -ClientId ([string]$In.clientId)) { $ClientTools += (Get-BKMemoryToolDefinition) }; continue }
        if ($Defs.Contains($T)) { $ClientTools += $Defs[$T] } else { $Missing += $T }
    }
    if ($Missing.Count -gt 0) {
        $Ext = Invoke-BKProjectTool -Name "_definitions" -In $In -Root $Root -Raw @{ names = @($Missing) }
        if ($Ext.ok -and $Ext.result.definitions) { foreach ($P in $Ext.result.definitions.PSObject.Properties) { $ClientTools += $P.Value } }
    }
    $ServerWanted = @($In.serverTools)
    $HasCode = ($ServerWanted -contains "code_execution")
    $State.CodeVariant = "new"          # code_execution_20250825 ; repli : 20250522 + en-tete bêta
    $State.UseExamples = $true
    $State.UseContextMgmt = ($env:BK_PROJECT_CONTEXT_MGMT -ne "0")
    $State.Fallbacks = 0
    $State.ExtraBeta = @()
    $WebUsed = 0
    $ContainerId = $null

    function Get-BKRequestTools {
        $L = @()
        $Left = [Math]::Max(0, $WebMax - $WebUsed)
        if ($Left -gt 0 -and $ServerWanted -contains "web_search") { $L += @{ type = "web_search_20250305"; name = "web_search"; max_uses = $Left } }
        if ($Left -gt 0 -and $ServerWanted -contains "web_fetch") { $L += @{ type = "web_fetch_20250910"; name = "web_fetch"; max_uses = $Left } }
        if ($HasCode) { $L += $(if ($State.CodeVariant -eq "new") { @{ type = "code_execution_20250825"; name = "code_execution" } } else { @{ type = "code_execution_20250522"; name = "code_execution" } }) }
        foreach ($CT in $ClientTools) {
            if ($State.UseExamples) { $L += $CT }
            else { $C2 = [ordered]@{}; foreach ($K in $CT.Keys) { if ($K -ne "input_examples" -and $K -ne "strict") { $C2[$K] = $CT[$K] } }; $L += $C2 }
        }
        return , $L
    }

    function Get-BKRequestHeaders {
        $Beta = @($State.ExtraBeta)
        if ($HasCode -and $State.CodeVariant -ne "new") { $Beta += "code-execution-2025-05-22" }
        if ($State.UseContextMgmt) { $Beta += "context-management-2025-06-27" }
        $H = @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" }
        if ($Beta.Count -gt 0) { $H["anthropic-beta"] = ($Beta | Select-Object -Unique) -join "," }
        return $H
    }

    # ---- premier message : fichiers d'entree (Files API) puis le contexte (le dernier bloc porte le point d'arret de cache)
    $Up = Send-BKStepInputFiles -In $In -PlainKey $PlainKey -HasCodeTool $HasCode
    if (@($Up.Ids).Count -gt 0) { $State.ExtraBeta += "files-api-2025-04-14" }
    $ContextText = ""
    try { $ContextText = [System.IO.File]::ReadAllText([string]$In.paths.context, [System.Text.Encoding]::UTF8) } catch { $ContextText = "(contexte illisible : lis workspace/ et handoff/)" }
    $FirstContent = @($Up.Blocks) + @(@{ type = "text"; text = $ContextText })
    $Messages = [System.Collections.ArrayList]@()
    [void]$Messages.Add(@{ role = "user"; content = $FirstContent })

    $Iteration = 0; $PauseRun = 0; $MaxTokRun = 0; $FinishReminders = 0; $Nudged = $false
    $LastText = ""; $AllFileIds = @(); $ProducedSeen = @{}
    $Identical = @{}; $LoopStop = $false
    $Report = $null; $EndKind = $null; $ExitReason = $null; $FinalStatus = $null; $ErrText = $null; $RetryAfterOut = $null
    $RefusalRetried = $false
    $NewChars = 0
    $PendingExtra = @()          # blocs texte a ajouter au prochain message utilisateur (rappel de budget, avertissement de boucle)
    $Response = $null

    try {
        while ($true) {
            $Now = (Get-Date).ToUniversalTime()
            if ($Now -ge $Soft) { $ExitReason = "deadline"; break }
            if ($Iteration -ge $MaxIterations) { $ExitReason = "iterations"; break }
            if (($Hard - $Now).TotalSeconds -lt 20) { $ExitReason = "deadline"; break }
            if ($Iteration -ge 1) {
                $Gate = Test-BKCostGate -Cost $Cost -NewChars $NewChars
                if ($Gate.Stop) { $Cost.Capped = $true; $Cost.CapReason = [string]$Gate.Reason; $ExitReason = "cost_ceiling"; Write-BKStepLog -In $In -Message "plafond de cout : $($Gate.Reason)"; break }
            }
            # rappel de budget a 20 % (une seule fois) : temps ou tours
            $SecLeft = [int]($Soft - $Now).TotalSeconds
            $IterLeft = $MaxIterations - $Iteration
            if (-not $Nudged -and $Iteration -ge 1 -and ($IterLeft -le [Math]::Ceiling($MaxIterations * 0.2) -or $SecLeft -le ($SoftTotalSec * 0.2))) {
                $Nudged = $true
                $PendingExtra += @{ type = "text"; text = (Get-BKProjectBudgetNudge -SecondsLeft $SecLeft -IterationsLeft $IterLeft) }
            }
            if ($PendingExtra.Count -gt 0) {
                $LastMsg = $Messages[$Messages.Count - 1]
                if ($LastMsg.role -eq "user" -and $LastMsg.content -is [System.Array]) { $LastMsg.content = @($LastMsg.content) + @($PendingExtra) }
                else { [void]$Messages.Add(@{ role = "user"; content = @($PendingExtra) }) }
                $PendingExtra = @()
            }
            if ($env:BK_PROJECT_CONVO_CACHE -ne "0") { Set-BKConversationCache -Messages $Messages }

            $Body = [ordered]@{ model = $Model; max_tokens = $MaxTokens; system = $SystemBlocks; messages = $Messages; tools = (Get-BKRequestTools) }
            if ($UseEffort) { $Body["output_config"] = @{ effort = [string]$In.effort } }
            if ($ContainerId) { $Body["container"] = $ContainerId }
            if ($State.UseContextMgmt) {
                $Body["context_management"] = @{ edits = @(@{ type = "clear_tool_uses_20250919"; trigger = @{ type = "input_tokens"; value = 70000 }; keep = @{ type = "tool_uses"; value = 4 }
                    clear_at_least = @{ type = "input_tokens"; value = 8000 }; exclude_tools = @("project_plan", "memory", "step_complete", "request_input", "note_decision") }) }
            }
            $Timeout = [int][Math]::Max(30, [Math]::Min($CallTimeout, ($Hard - (Get-Date).ToUniversalTime()).TotalSeconds - 3))

            $Call = Invoke-BKMessagesCall -Body $Body -Headers (Get-BKRequestHeaders) -TimeoutSec $Timeout -In $In
            if (-not $Call.ok) {
                $Txt = [string]$Call.text
                if ($Call.kind -eq "unavailable") { $FinalStatus = "RETRY_LATER"; $ExitReason = "api_unavailable"; $RetryAfterOut = $Call.retryAfterSec; $ErrText = "API_UNAVAILABLE"; break }
                if ($Call.kind -eq "bad_request" -and $State.Fallbacks -lt 4) {
                    if ($State.UseContextMgmt -and $Txt -match 'context_management|clear_tool_uses|context-management') { $State.UseContextMgmt = $false; $State.Fallbacks++; Write-BKStepLog -In $In -Message "context_management refuse : reessai sans"; continue }
                    if ($State.UseExamples -and $Txt -match 'input_examples|strict') { $State.UseExamples = $false; $State.Fallbacks++; Write-BKStepLog -In $In -Message "input_examples refuse : reessai sans"; continue }
                    if ($HasCode -and $State.CodeVariant -eq "new" -and $Txt -match 'tool|beta|code_execution|web_fetch|web_search') { $State.CodeVariant = "old"; $State.Fallbacks++; Write-BKStepLog -In $In -Message "outil refuse : repli code_execution_20250522"; continue }
                }
                if ($Call.status -eq 413 -or $Txt -match 'prompt is too long|too long|context window|exceeds the (context|maximum)') { $FinalStatus = "FAILED"; $ExitReason = "iterations"; $ErrText = "CONTEXT_TOO_LONG"; break }
                $FinalStatus = "FAILED"; $ExitReason = "invalid_input"; $ErrText = "API_ERROR_" + $Call.status
                Write-BKStepLog -In $In -Message ("erreur API non recuperable (HTTP " + $Call.status + ") : " + ($Txt.Substring(0, [Math]::Min(180, $Txt.Length))))
                break
            }
            $Response = $Call.response
            $Iteration++
            Add-BKCallCost -Cost $Cost -Response $Response
            Write-BKCostFile -In $In -Cost $Cost -Iteration $Iteration
            $WebUsed += [int]$Response.usage.server_tool_use.web_search_requests + [int]$Response.usage.server_tool_use.web_fetch_requests
            if ($Response.container -and $Response.container.id) { $ContainerId = [string]$Response.container.id }
            $Text = Get-ResponseText -Resp $Response
            if (-not [string]::IsNullOrWhiteSpace($Text)) { $LastText = $Text }
            $FileIds = @(Get-CodeExecFileIds -Resp $Response) | Where-Object { $_ -and -not $ProducedSeen.ContainsKey($_) }
            foreach ($Fid in $FileIds) { $ProducedSeen[$Fid] = $true }
            if (@($FileIds).Count -gt 0) { Import-BKSandboxFiles -In $In -PlainKey $PlainKey -FileIds $FileIds -Root $Root -Imported $Imported -ImportErrors $ImportErrors }

            $Stop = [string]$Response.stop_reason
            Write-BKStepLog -In $In -Message "tour $Iteration : stop_reason=$Stop"

            if ($Stop -eq "refusal") {
                Write-BKStepLog -In $In -Message ("refus du modele : " + (($Response.stop_details | ConvertTo-Json -Depth 4 -Compress) -replace '\s+', ' '))
                if (-not $RefusalRetried) {
                    $RefusalRetried = $true; $Model = Get-BKOtherModel -Model $Model
                    $Cost = New-BKMissionCostSwitch -Cost $Cost -Root $Root -Model $Model
                    $UseEffort = ($In.effort -and $Model -notlike "claude-haiku-4*")
                    Write-BKStepLog -In $In -Message "refus : un essai avec le modele $Model"
                    continue
                }
                $FinalStatus = "FAILED"; $ExitReason = "refusal"; $ErrText = "MODEL_REFUSAL"; break
            }
            if ($Stop -eq "model_context_window_exceeded") { $FinalStatus = "FAILED"; $ExitReason = "iterations"; $ErrText = "CONTEXT_TOO_LONG"; break }

            if ($Stop -eq "pause_turn") {
                $PauseRun++
                if ($PauseRun -gt 5) { $ExitReason = "iterations"; break }
                $Iteration--                                    # une continuation de tour serveur ne consomme pas d'iteration
                [void]$Messages.Add(@{ role = "assistant"; content = $Response.content })
                continue
            }
            $PauseRun = 0

            if ($Stop -eq "max_tokens") {
                $MaxTokRun++
                if ($MaxTokRun -gt 2) { $ExitReason = "iterations"; break }
                $HasToolUse = @($Response.content | Where-Object { $_.type -eq "tool_use" }).Count -gt 0
                if ($HasToolUse) {
                    [void]$Messages.Add(@{ role = "user"; content = @(@{ type = "text"; text = "Ta derniere reponse a ete coupee (trop longue) et son appel d'outil n'a pas pu etre execute. Recommence avec un contenu plus court : ecris un fichier plus petit a la fois." }) })
                } else {
                    [void]$Messages.Add(@{ role = "assistant"; content = $Response.content })
                    [void]$Messages.Add(@{ role = "user"; content = @(@{ type = "text"; text = "Continue." }) })
                }
                continue
            }

            $ToolUses = @($Response.content | Where-Object { $_.type -eq "tool_use" })
            if ($ToolUses.Count -eq 0) {
                # le modele s'arrete sans outil
                if ($Kind -eq "answer") { $EndKind = "answer"; break }
                $FinishReminders++
                if ($FinishReminders -gt 2) { $ExitReason = "iterations"; break }
                [void]$Messages.Add(@{ role = "assistant"; content = $Response.content })
                [void]$Messages.Add(@{ role = "user"; content = @(@{ type = "text"; text = (Get-BKProjectFinishReminder) }) })
                $NewChars = 0
                continue
            }

            [void]$Messages.Add(@{ role = "assistant"; content = $Response.content })
            $ToolResults = @()
            $NewChars = 0
            foreach ($TU in $ToolUses) {
                $Key = [string]$TU.name + "|" + ($TU.input | ConvertTo-Json -Depth 20 -Compress)
                $Identical[$Key] = 1 + [int]$Identical[$Key]
                $R = Invoke-BKStepToolUse -ToolUse $TU -In $In -Root $Root -State $State
                if ($R.Mutated) { $Identical = @{} }
                $Content = $R.Content
                if ($Identical.ContainsKey($Key) -and $Identical[$Key] -ge 3) {
                    $Warn = Get-BKProjectLoopWarning
                    $Content = if ($Content -is [string]) { $Content + "`n" + $Warn } else { @($Content) + @(@{ type = "text"; text = $Warn }) }
                    if ($Identical[$Key] -ge 4) { $LoopStop = $true }
                }
                $ToolResults += (New-BKToolResultBlock -Id ([string]$TU.id) -Content $Content -IsError ([bool]$R.IsError))
                $NewChars += $(if ($Content -is [string]) { $Content.Length } else { 2000 })
                if ($R.End -and -not $EndKind) { $EndKind = $R.End; $Report = $R.Report }
            }
            foreach ($Blk in @($Response.content)) { if ($Blk -and ([string]$Blk.type) -like '*_tool_result') { $NewChars += ($Blk | ConvertTo-Json -Depth 12 -Compress).Length } }
            if ($EndKind) { break }
            [void]$Messages.Add(@{ role = "user"; content = @($ToolResults) })
            if ($State.ReportRejections -ge 3) { $ExitReason = "iterations"; $ErrText = "STEP_REPORT_INVALID"; break }
            if ($LoopStop) { $ExitReason = "iterations"; $ErrText = "LOOP_DETECTED"; break }
        }

        # ---- finalisation forcee : un dernier appel SANS outil (tool_choice none) pour obtenir le rapport, si le temps et le cout le permettent
        if (-not $EndKind -and -not $FinalStatus -and $ExitReason -in @("deadline", "iterations") -and $Iteration -ge 1 -and $ErrText -ne "LOOP_DETECTED" -and $Kind -ne "verify") {
            $Left = ($Hard - (Get-Date).ToUniversalTime()).TotalSeconds
            $Gate = Test-BKCostGate -Cost $Cost -NewChars 500
            if ($Left -gt 25 -and -not $Gate.Stop) {
                try {
                    $LastMsg = $Messages[$Messages.Count - 1]
                    $Fin = @{ type = "text"; text = (Get-BKProjectFinalizationRequest) }
                    if ($LastMsg.role -eq "user" -and $LastMsg.content -is [System.Array]) { $LastMsg.content = @($LastMsg.content) + @($Fin) } else { [void]$Messages.Add(@{ role = "user"; content = @($Fin) }) }
                    if ($env:BK_PROJECT_CONVO_CACHE -ne "0") { Set-BKConversationCache -Messages $Messages }
                    $FBody = [ordered]@{ model = $Model; max_tokens = 3000; system = $SystemBlocks; messages = $Messages; tools = (Get-BKRequestTools); tool_choice = @{ type = "none" } }
                    if ($UseEffort) { $FBody["output_config"] = @{ effort = [string]$In.effort } }
                    if ($ContainerId) { $FBody["container"] = $ContainerId }
                    $FC = Invoke-BKMessagesCall -Body $FBody -Headers (Get-BKRequestHeaders) -TimeoutSec ([int][Math]::Max(20, [Math]::Min(120, $Left - 5))) -In $In
                    if ($FC.ok) {
                        $Iteration++
                        Add-BKCallCost -Cost $Cost -Response $FC.response
                        Write-BKCostFile -In $In -Cost $Cost -Iteration $Iteration
                        $FT = Get-ResponseText -Resp $FC.response
                        if (-not [string]::IsNullOrWhiteSpace($FT)) { $LastText = $FT }
                    }
                } catch { Write-BKStepLog -In $In -Message "finalisation forcee impossible" }
            }
        }
    }
    catch {
        $FinalStatus = "FAILED"; $ExitReason = "invalid_input"; $ErrText = "RUNNER_ERROR_" + $_.Exception.GetType().Name
        Write-BKStepLog -In $In -Message ("erreur du lanceur : " + $_.Exception.Message)
    }
    finally {
        Remove-BKStepUploads -PlainKey $PlainKey -Ids $Up.Ids -In $In
    }

    $Out = $null
    if ($FinalStatus -eq "RETRY_LATER") {
        $Out = New-BKStepResult -Status "RETRY_LATER" -ExitReason "api_unavailable" -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported -Err $ErrText -RetryAfter $RetryAfterOut
    }
    elseif ($FinalStatus -eq "FAILED") {
        $Out = New-BKStepResult -Status "FAILED" -ExitReason $ExitReason -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported -Err $ErrText
    }
    elseif ($EndKind -eq "complete") {
        $St = [string]$Report.status
        if ($St -notin @("DONE", "PARTIAL", "NEEDS_INPUT", "BLOCKED")) { $St = "DONE" }
        $Out = New-BKStepResult -Status $St -ExitReason "step_complete" -Report $Report -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported
    }
    elseif ($EndKind -eq "blocked") {
        $Rep = [ordered]@{ status = "BLOCKED"; summary = [string]$Report.detail; blocked = $Report; remaining = @() }
        $Out = New-BKStepResult -Status "BLOCKED" -ExitReason "step_blocked" -Report $Rep -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported
    }
    elseif ($EndKind -eq "answer") {
        $Out = New-BKStepResult -Status "DONE" -ExitReason "step_complete" -AnswerText $LastText -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported
    }
    else {
        $Reason = if ($ExitReason) { $ExitReason } else { "iterations" }
        $Rep = New-BKMinimalReport -In $In -Since $Started -LastText $LastText -Reason $Reason -Imported $Imported
        if ($Kind -eq "answer" -and $LastText) {
            $Out = New-BKStepResult -Status "DONE" -ExitReason "step_complete" -AnswerText $LastText -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported
        } else {
            $Out = New-BKStepResult -Status "PARTIAL" -ExitReason $Reason -Report $Rep -Cost $Cost -In $In -Started $Started -Iterations $Iteration -Imported $Imported -Err $ErrText
        }
    }
    if ($ImportErrors.Count -gt 0) { $Out["importErrors"] = @($ImportErrors) }
    return $Out
}

function New-BKMissionCostSwitch {
    # Changement de modele en cours d'etape (un essai apres un refus) : on garde le cumul deja engage, on change seulement le tarif.
    param($Cost, [string]$Root, [string]$Model)
    $Fresh = New-BKMissionCost -Pricing (Get-BKPricing -Root $Root) -Model $Model -CeilingChf $Cost.CeilingChf
    foreach ($K in @("Calls", "InputTokens", "OutputTokens", "CacheWriteTokens", "CacheReadTokens", "WebSearches", "Usd", "Complete", "LastPromptTokens", "LastOutputTokens", "MaxOutputTokens", "LastWebSearches")) { $Fresh[$K] = $Cost[$K] }
    return $Fresh
}
