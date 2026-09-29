# =====================================================================
# BK-AI-WORKERS — Memoire de conversation (2026-09-29, demande explicite
# de Kader : "on ne peut pas revenir sur une conversation qu'on avait
# avec un agent"). Avant ce fichier, chaque appel au modele ne contenait
# QUE l'objectif du moment ($Messages = un seul message) : un Worker ne
# se souvenait jamais de rien, "reprends la mission precedente" ne
# pouvait pas fonctionner.
#
# Principe : on ne cree AUCUN nouveau stockage. Chaque mission ecrit deja
# un fichier runtime/tasks/TASK-<id>.json (Submit-Task.ps1) avec
# ClientId, Worker, Request et Result.Answer. On relit simplement les
# dernieres missions REUSSIES de CE client avec CE Worker et on les
# remet devant le modele comme un vrai historique de conversation
# (role user/assistant alterne), avant l'objectif du jour.
#
# Garde-fous :
#   - Jamais entre deux clients differents (filtre strict ClientId).
#   - Jamais pour l'essai public gratuit (CLI-TRIAL-PUBLIC est un SEUL
#     identifiant partage par tous les visiteurs anonymes du monde entier
#     — melanger leurs echanges serait une fuite de vie privee entre
#     inconnus, pas une fonctionnalite).
#   - Seules les missions Status=EXECUTED et Authorized=true comptent
#     (jamais une erreur ou un blocage presente comme si c'etait une
#     vraie reponse passee).
#   - Nombre de tours et longueur des reponses plafonnes (cout/latence),
#     jamais tout l'historique complet.
# =====================================================================

function Get-BKRecentConversationTurns {
    param(
        [Parameter(Mandatory = $true)][string]$Root,
        [Parameter(Mandatory = $true)][string]$ClientId,
        [Parameter(Mandatory = $true)][string]$WorkerId,
        [int]$MaxTurns = 3,
        [int]$MaxAnswerChars = 900
    )

    if ($ClientId -eq "CLI-TRIAL-PUBLIC") { return @() }

    $Dir = Join-Path $Root "runtime/tasks"
    if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { return @() }

    $WorkerUpper = $WorkerId.ToString().ToUpperInvariant()
    $Records = @()

    foreach ($File in Get-ChildItem -LiteralPath $Dir -Filter "TASK-*.json" -File -ErrorAction SilentlyContinue) {
        try {
            $Data = Get-Content -LiteralPath $File.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        if ($null -eq $Data) { continue }
        if ([string]$Data.ClientId -ne $ClientId) { continue }
        if ([string]$Data.Worker -ne $WorkerUpper) { continue }
        if ($Data.Status -ne "EXECUTED" -or $Data.Authorized -ne $true) { continue }

        $Req = [string]$Data.Request
        $Ans = [string]$Data.Result.Answer
        if ([string]::IsNullOrWhiteSpace($Req) -or [string]::IsNullOrWhiteSpace($Ans)) { continue }

        $Records += [pscustomobject]@{
            CreatedAtUtc = [string]$Data.CreatedAtUtc
            Request      = $Req
            Answer       = $Ans
        }
    }

    if ($Records.Count -eq 0) { return @() }

    $Recent = $Records | Sort-Object CreatedAtUtc -Descending | Select-Object -First $MaxTurns
    $Ordered = $Recent | Sort-Object CreatedAtUtc

    $Turns = @()
    foreach ($R in $Ordered) {
        $Ans = $R.Answer
        if ($Ans.Length -gt $MaxAnswerChars) {
            $Ans = $Ans.Substring(0, $MaxAnswerChars) + " […]"
        }
        $Turns += @{ role = "user"; content = $R.Request }
        $Turns += @{ role = "assistant"; content = $Ans }
    }
    return $Turns
}
