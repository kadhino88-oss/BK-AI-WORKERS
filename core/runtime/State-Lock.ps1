# =====================================================================
# BK-AI-WORKERS - Verrou inter-processus + ecriture atomique des fichiers
# d'etat JSON partages (2026-09-28).
#
# Pourquoi : chaque mission lance ses propres processus PowerShell, qui
# relisent / modifient / reecrivent entierement des fichiers d'etat
# communs (bindings.json, grants.json, records.json...). Sans verrou, deux
# missions simultanees pouvaient (a) melanger leurs ecritures et laisser un
# JSON illisible -> TOUTES les missions suivantes bloquees
# (AI_AUTHORIZATION_BLOCKED, incident du 2026-09-28), ou (b) perdre une
# mise a jour (la derniere ecriture ecrase la precedente).
#
# Usage dans un module :
#   . (Join-Path $Root "core/runtime/State-Lock.ps1")
#   function Register-Truc {
#       Invoke-BKStateLocked {
#           $items = @(Read-Truc)        # lecture
#           ...                          # modification
#           Write-Truc -Items $items     # ecriture (via Write-BKStateFileAtomic)
#       }
#   }
#
# Regles :
# - Le verrou est UNIQUE pour tous les fichiers d'etat (pas d'interblocage
#   entre modules) et reentrant dans un meme processus (un module verrouille
#   peut appeler un autre module verrouille).
# - Jamais de processus enfant, d'appel reseau ou d'attente longue a
#   l'interieur d'un bloc verrouille : uniquement lecture/modification/
#   ecriture de fichiers.
# - Si un processus meurt en tenant le verrou (mission tuee au bout du
#   delai), le suivant le recupere automatiquement (AbandonedMutexException).
# =====================================================================

if (-not (Get-Command -Name Invoke-BKStateLocked -CommandType Function -ErrorAction SilentlyContinue)) {

    # "Global\" : meme verrou pour les processus lances par le serveur web ET
    # pour ceux lances par la tache planifiee (docker exec, autre session).
    $Script:BKStateLockName = "Global\BK-AI-WORKERS-STATE-LOCK"

    function Invoke-BKStateLocked {
        param(
            [Parameter(Mandatory = $true, Position = 0)][scriptblock]$ScriptBlock,
            [int]$TimeoutSeconds = 30
        )

        $Mutex = $null
        try {
            $Mutex = New-Object System.Threading.Mutex($false, $Script:BKStateLockName)
        } catch {
            # Plateforme sans nom "Global\" (tres ancien runtime) : repli local.
            $Mutex = New-Object System.Threading.Mutex($false, "BK-AI-WORKERS-STATE-LOCK")
        }

        $Owned = $false
        try {
            try {
                $Owned = $Mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
            } catch [System.Threading.AbandonedMutexException] {
                # Le detenteur precedent est mort : le verrou nous est acquis.
                $Owned = $true
            }
            if (-not $Owned) { throw "STATE_LOCK_TIMEOUT" }

            return & $ScriptBlock
        }
        finally {
            if ($Owned) { try { $Mutex.ReleaseMutex() } catch { } }
            $Mutex.Dispose()
        }
    }

    function Write-BKStateFileAtomic {
        <#
        Ecrit $Content dans un fichier temporaire du MEME dossier, puis le
        substitue au fichier cible en une seule operation : un lecteur voit
        toujours soit l'ancien fichier complet, soit le nouveau, jamais un
        fichier a moitie ecrit. UTF-8 sans BOM (comme les modules existants).
        #>
        param(
            [Parameter(Mandatory = $true)][string]$Path,
            [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
        )

        $Dir = Split-Path -Parent $Path
        if ($Dir -and -not (Test-Path -LiteralPath $Dir -PathType Container)) {
            New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        }
        $Tmp = Join-Path $Dir (".tmp-" + [System.IO.Path]::GetFileName($Path) + "-" + [guid]::NewGuid().ToString("N"))

        [System.IO.File]::WriteAllText($Tmp, $Content, [System.Text.UTF8Encoding]::new($false))
        try {
            if (Test-Path -LiteralPath $Path -PathType Leaf) {
                try {
                    # .NET Core / PowerShell 7 : remplacement atomique (rename).
                    [System.IO.File]::Move($Tmp, $Path, $true)
                } catch [System.Management.Automation.MethodException] {
                    # Windows PowerShell 5.1 (.NET Framework) : pas de surcharge
                    # Move(src, dst, overwrite) -> Replace, atomique sous NTFS.
                    [System.IO.File]::Replace($Tmp, $Path, [NullString]::Value)
                }
            } else {
                [System.IO.File]::Move($Tmp, $Path)
            }
        } finally {
            if (Test-Path -LiteralPath $Tmp -PathType Leaf) {
                Remove-Item -LiteralPath $Tmp -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
