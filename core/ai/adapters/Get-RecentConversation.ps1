# =====================================================================
# BK-AI-WORKERS - Memoire de conversation, version 2 (2026-10-12).
#
# Demande de Kader : "les agents n'arrivent pas a se souvenir de la conversation, ce qui n'est pas normal : Claude Code
# a cette faculte et tous mes Workers doivent l'avoir". Version 1 (2026-09-29) relisait les 3 dernieres missions
# terminees de CE client avec CE Worker, reponses COUPEES a 900 caracteres : la fin d'une reponse (la ou se trouvent les
# questions posees et les prochaines etapes) etait perdue, deux tours plus loin le Worker ne savait plus rien, et chaque
# mission relisait TOUS les fichiers TASK-*.json du serveur (cout proportionnel au nombre total de missions de tous les clients).
#
# Version 2 :
#   - UN fil par (client, Worker) : runtime/threads/<ClientId>/<WORKER>.jsonl, une ligne JSON par tour, ecrite par
#     l'adaptateur a la fin de chaque mission reussie (Add-BKConversationTurn). Lecture = la fin du fichier seulement.
#   - Rappel par PALIERS, comme une compaction : les 2 derniers tours en entier (jusqu'a 6000 caracteres, debut + FIN
#     conservees), les 6 precedents condenses (1500 caracteres, debut + fin), les 30 plus anciens resumes en une ligne
#     par demande dans un message "memoire". Les fichiers produits et les actions preparees sont rappeles.
#   - Une seule fois, pour un fil qui n'existe pas encore : reconstruction depuis les anciens TASK-*.json (migration).
# Garde-fous inchanges : jamais entre deux clients (le chemin contient le ClientId, valide par une liste blanche de
# caracteres), jamais pour l'essai public (CLI-TRIAL-PUBLIC = un identifiant partage par des inconnus), seules les missions
# reussies comptent. Le fil est supprime avec le compte du client (server.py).
# =====================================================================

$Script:BKTrialClientId = "CLI-TRIAL-PUBLIC"

function Get-BKThreadPath {
    param([string]$Root, [string]$ClientId, [string]$WorkerId)
    if ($ClientId -notmatch '^[A-Za-z0-9_-]{1,80}$' -or $WorkerId -notmatch '^[A-Za-z0-9_-]{1,40}$') { return $null }
    return (Join-Path (Join-Path (Join-Path $Root "runtime/threads") $ClientId) ($WorkerId.ToUpperInvariant() + ".jsonl"))
}

function Limit-BKHeadTail {
    # Garde le DEBUT et la FIN d'un texte : la fin d'une reponse contient souvent les questions et les prochaines etapes.
    param([string]$Text, [int]$Max)
    if ($null -eq $Text) { return "" }
    if ($Text.Length -le $Max) { return $Text }
    $Head = [int][Math]::Floor($Max * 0.6)
    $Tail = $Max - $Head
    return $Text.Substring(0, $Head) + "`n[...]`n" + $Text.Substring($Text.Length - $Tail)
}

function Add-BKConversationTurn {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [string]$TaskId = "",
        [string]$Request = "",
        [string]$Answer = "",
        $Files = @(),
        $Actions = @()
    )
    try {
        if ($ClientId -eq $Script:BKTrialClientId) { return }
        if ([string]::IsNullOrWhiteSpace($Request) -or [string]::IsNullOrWhiteSpace($Answer)) { return }
        $Path = Get-BKThreadPath -Root $Root -ClientId $ClientId -WorkerId $WorkerId
        if (-not $Path) { return }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null

        $FileNames = @(@($Files) | Where-Object { $_ } | ForEach-Object { [string]$_.filename } | Where-Object { $_ })
        $ActionList = @(@($Actions) | Where-Object { $_ } | ForEach-Object { [ordered]@{ connectorId = [string]$_.connectorId; operation = [string]$_.operation; status = [string]$_.status } })
        $Entry = [ordered]@{
            ts      = (Get-Date).ToUniversalTime().ToString("o")
            taskId  = $TaskId
            request = (Limit-BKHeadTail -Text $Request -Max 8000)
            answer  = (Limit-BKHeadTail -Text $Answer -Max 20000)
            files   = $FileNames
            actions = $ActionList
        }
        $Line = ($Entry | ConvertTo-Json -Compress -Depth 5)
        [System.IO.File]::AppendAllText($Path, $Line + "`n", [System.Text.UTF8Encoding]::new($false))

        # Memoire ILLIMITEE : un fil trop gros est ARCHIVE (jamais supprime ni tronque) et le fil actif repart avec les 60 derniers
        # tours ; l'outil "memory" (Client-Memory.ps1) cherche dans tous les fichiers .jsonl du client, archives comprises.
        if ((Get-Item -LiteralPath $Path).Length -gt 2MB) {
            $Keep = @(Get-Content -LiteralPath $Path -Tail 60 -Encoding UTF8)
            $Archive = [System.IO.Path]::ChangeExtension($Path, $null).TrimEnd('.') + ".archive-" + (Get-Date).ToUniversalTime().ToString("yyyyMMddHHmmss") + ".jsonl"
            Move-Item -LiteralPath $Path -Destination $Archive -Force
            [System.IO.File]::WriteAllText($Path, (($Keep -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        }
    }
    catch { }   # la memoire ne doit JAMAIS faire echouer une mission
}

function Read-BKThreadEntries {
    # Entrees du fil, de la plus ancienne a la plus recente. Si le fil n'existe pas : migration depuis les anciens TASK-*.json.
    param([string]$Root, [string]$ClientId, [string]$WorkerId, [int]$Tail = 120)
    $Path = Get-BKThreadPath -Root $Root -ClientId $ClientId -WorkerId $WorkerId
    if (-not $Path) { return @() }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        $Dir = Join-Path $Root "runtime/tasks"
        if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }
        $WorkerUpper = $WorkerId.ToString().ToUpperInvariant()
        $Records = @()
        foreach ($File in Get-ChildItem -LiteralPath $Dir -Filter "TASK-*.json" -File -ErrorAction SilentlyContinue) {
            try { $Data = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            if ($null -eq $Data) { continue }
            if ([string]$Data.ClientId -ne $ClientId -or [string]$Data.Worker -ne $WorkerUpper) { continue }
            if ($Data.Status -ne "EXECUTED" -or $Data.Authorized -ne $true) { continue }
            $Req = [string]$Data.Request; $Ans = [string]$Data.Result.Answer
            if ([string]::IsNullOrWhiteSpace($Req) -or [string]::IsNullOrWhiteSpace($Ans)) { continue }
            $Records += [pscustomobject]@{ ts = [string]$Data.CreatedAtUtc; taskId = [string]$Data.TaskId; request = $Req; answer = $Ans; files = @(); actions = @() }
        }
        if ($Records.Count -eq 0) { return @() }
        $Sorted = @($Records | Sort-Object ts | Select-Object -Last 40)
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
            $Lines = $Sorted | ForEach-Object { ($_ | ConvertTo-Json -Compress -Depth 5) }
            [System.IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        } catch { }
        return $Sorted
    }

    $Out = @()
    foreach ($Line in @(Get-Content -LiteralPath $Path -Tail $Tail -Encoding UTF8)) {
        if ([string]::IsNullOrWhiteSpace($Line)) { continue }
        try { $E = $Line | ConvertFrom-Json } catch { continue }   # ligne abimee : ignoree
        if ($null -eq $E -or [string]::IsNullOrWhiteSpace([string]$E.request) -or [string]::IsNullOrWhiteSpace([string]$E.answer)) { continue }
        $Out += $E
    }
    return $Out
}

function Get-BKRecentConversationTurns {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [int]$FullTurns = 2,
        [int]$MidTurns = 6,
        [int]$DigestTurns = 30,
        [int]$FullAnswerChars = 6000,
        [int]$MidAnswerChars = 1500
    )

    if ($ClientId -eq $Script:BKTrialClientId) { return @() }
    $Entries = @(Read-BKThreadEntries -Root $Root -ClientId $ClientId -WorkerId $WorkerId)
    if ($Entries.Count -eq 0) { return @() }

    $N = $Entries.Count
    $FullStart = [Math]::Max(0, $N - $FullTurns)
    $MidStart = [Math]::Max(0, $FullStart - $MidTurns)
    $DigestStart = [Math]::Max(0, $MidStart - $DigestTurns)

    $Turns = @()
    if ($MidStart -gt $DigestStart) {
        $Lines = @()
        for ($i = $DigestStart; $i -lt $MidStart; $i++) {
            $E = $Entries[$i]
            $Day = if ([string]$E.ts.Length -ge 10) { ([string]$E.ts).Substring(0, 10) } else { "" }
            $Lines += "- " + $Day + " : " + ((([string]$E.request) -replace '\s+', ' ').Trim() | ForEach-Object { if ($_.Length -gt 160) { $_.Substring(0, 160) + "..." } else { $_ } })
        }
        $Turns += @{ role = "user"; content = "[Memoire de la conversation - demandes plus anciennes, de la plus ancienne a la plus recente]`n" + ($Lines -join "`n") }
        $Turns += @{ role = "assistant"; content = "Note : je me souviens de ces echanges." }
    }

    for ($i = $MidStart; $i -lt $N; $i++) {
        $E = $Entries[$i]
        $Max = if ($i -ge $FullStart) { $FullAnswerChars } else { $MidAnswerChars }
        $Ans = Limit-BKHeadTail -Text ([string]$E.answer) -Max $Max
        $Extra = @()
        if (@($E.files).Count -gt 0) { $Extra += "Fichiers produits : " + (@($E.files) -join ", ") }
        foreach ($A in @($E.actions)) {
            if ($A) { $Extra += "Action preparee : " + [string]$A.connectorId + " " + [string]$A.operation + " (" + [string]$A.status + ")" }
        }
        if ($Extra.Count -gt 0) { $Ans = $Ans + "`n[" + ($Extra -join " ; ") + "]" }
        $Turns += @{ role = "user"; content = (Limit-BKHeadTail -Text ([string]$E.request) -Max 3000) }
        $Turns += @{ role = "assistant"; content = $Ans }
    }
    return $Turns
}
