# =====================================================================
# BK-AI-WORKERS - Fonctions communes des adaptateurs Anthropic (extraites de ANTHROPIC-ADAPTER.ps1, 2026-10-19).
#
# Extraction MECANIQUE, sans changement de comportement : ces fonctions servaient deja a la boucle de mission de
# ANTHROPIC-ADAPTER.ps1 ; elles sont maintenant partagees avec la boucle d'une ETAPE DE PROJET (Project-Loop.ps1, docs/AUTONOMY-ENGINE.md,
# section 3.2). A dot-sourcer depuis un script qui definit $ProjectRoot (la racine du depot) et qui a deja charge Connector-Dispatch.ps1
# ($Script:OperationTable).
# =====================================================================

# Outil "use_connector", pre-autorisation et garde-fou d'approbation : core/ai/adapters/Connector-Tool.ps1 (une seule implementation, partagee avec
# OPENAI-COMPAT-ADAPTER.ps1 ; fusion des extractions paralleles du 2026-10-19 et du 2026-10-25).
. (Join-Path $ProjectRoot "core/ai/adapters/Connector-Tool.ps1")

function Get-ResponseText {
    # Texte (blocs "text") d'UNE reponse de l'API.
    param($Resp)
    if ($null -eq $Resp -or $null -eq $Resp.content) { return "" }
    return (@($Resp.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n").Trim()
}

function Get-CodeExecFileIds {
    # file_id des fichiers produits par l'execution de code dans UNE reponse de l'API.
    param($Resp)
    $Ids = @()
    if ($null -eq $Resp -or $null -eq $Resp.content) { return $Ids }
    foreach ($Block in $Resp.content) {
        if ($null -eq $Block) { continue }
        $IsCurrent = ($Block.type -eq "bash_code_execution_tool_result")
        $IsLegacy  = ($Block.type -eq "code_execution_tool_result")
        if (-not ($IsCurrent -or $IsLegacy)) { continue }
        $Inner = $Block.content
        if ($null -eq $Inner -or $null -eq $Inner.content) { continue }
        $WantType = if ($IsCurrent) { "bash_code_execution_output" } else { "code_execution_output" }
        foreach ($Entry in @($Inner.content)) {
            if ($null -eq $Entry) { continue }
            if ($Entry.type -eq $WantType -and $Entry.file_id) { $Ids += [string]$Entry.file_id }
        }
    }
    return $Ids
}


function Save-BKCodeExecFiles {
    <#
    Capture des fichiers generes (2026-10-08, extrait le 2026-10-19). Les Workers peuvent produire un livrable (Excel/Word/PDF/CSV/image)
    via code execution. Anthropic renvoie alors des blocs resultat contenant un file_id ; on recupere les metadonnees puis les octets
    via la Files API et on depose chaque fichier dans $DestDir. Chaque fichier est SUPPRIME chez Anthropic des qu'il est telecharge (les
    fichiers du client ne doivent pas y rester : ils persistent jusqu'a un DELETE, partages par tout le compte API).
    Tout est encapsule dans un try/catch : la moindre erreur laisse le resultat tel quel (jamais de throw depuis cette fonction).
    Renvoie @{ Captured = @(...) ; Skipped = @(...) } ; chemin d'un fichier capture = "$PathPrefix/<nom>".
    #>
    param(
        [string[]]$FileIds,
        [string]$PlainKey,
        [string]$DestDir,
        [string]$PathPrefix,
        [int]$MaxFiles = 10,
        [long]$MaxFileBytes = 25MB,
        [long]$MaxTotalBytes = 60MB
    )
    $CapturedFiles = @()
    $SkippedFiles = @()
    try {
        $FileIds = @($FileIds | Select-Object -Unique)
        $TotalBytes = 0
        $AuthHdr = @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" }

        $Counter = 0
        foreach ($FileId in $FileIds) {
            $Counter++
            $FileName = $null; $Mime = $null; $SizeBytes = 0
            try {
                $Meta = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/files/$FileId" `
                    -Headers @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" } -TimeoutSec 60
                $FileName  = [string]$Meta.filename
                $Mime      = [string]$Meta.mime_type
                $SizeBytes = [long]$Meta.size_bytes
            }
            catch {
                $FileName  = "$FileId.bin"
                $Mime      = "application/octet-stream"
                $SizeBytes = 0
            }
            if ([string]::IsNullOrWhiteSpace($Mime)) { $Mime = "application/octet-stream" }

            # Plafonds (serveur de 3,8 Go partage entre tous les clients) : un fichier trop gros ou en trop est ignore
            # et sa copie chez Anthropic supprimee.
            if (($Counter -gt $MaxFiles) -or ($SizeBytes -gt $MaxFileBytes) -or (($TotalBytes + $SizeBytes) -gt $MaxTotalBytes)) {
                $SkippedFiles += $FileName
                try { Invoke-RestMethod -Uri "https://api.anthropic.com/v1/files/$FileId" -Method Delete -Headers $AuthHdr -TimeoutSec 30 | Out-Null } catch { }
                continue
            }

            # Nom de fichier sur : on ne garde que le basename, puis on ne
            # conserve que [A-Za-z0-9._-], on borne la longueur.
            $SafeName = ""
            if (-not [string]::IsNullOrWhiteSpace($FileName)) {
                $Leaf = $FileName -replace '.*[\\/]', ''
                $SafeName = ($Leaf -replace '[^A-Za-z0-9._-]', '_')
                if ($SafeName.Length -gt 120) { $SafeName = $SafeName.Substring(0, 120) }
            }
            if ([string]::IsNullOrWhiteSpace($SafeName) -or $SafeName -eq "." -or $SafeName -eq "..") {
                $SafeName = "$FileId.bin"
            }

            $DestPath = Join-Path $DestDir $SafeName
            if (Test-Path -LiteralPath $DestPath) {
                $SafeName = "$Counter-$SafeName"
                $DestPath = Join-Path $DestDir $SafeName
            }
            New-Item -ItemType Directory -Force -Path $DestDir | Out-Null

            Invoke-WebRequest -Uri "https://api.anthropic.com/v1/files/$FileId/content" `
                -Headers $AuthHdr -TimeoutSec 240 -OutFile $DestPath | Out-Null

            # Taille reelle (la metadonnee peut manquer) puis suppression de la copie chez Anthropic : les fichiers du client
            # ne doivent pas rester stockes la-bas (ils y persistent jusqu'a un DELETE, partages par tout le compte API).
            $RealLen = (Get-Item -LiteralPath $DestPath).Length
            try { Invoke-RestMethod -Uri "https://api.anthropic.com/v1/files/$FileId" -Method Delete -Headers $AuthHdr -TimeoutSec 30 | Out-Null } catch { }
            if (($RealLen -gt $MaxFileBytes) -or (($TotalBytes + $RealLen) -gt $MaxTotalBytes)) {
                Remove-Item -LiteralPath $DestPath -Force -ErrorAction SilentlyContinue
                $SkippedFiles += $SafeName
                continue
            }
            $TotalBytes += $RealLen

            $CapturedFiles += [ordered]@{
                fileId    = $FileId
                filename  = $SafeName
                mime      = $Mime
                sizeBytes = $SizeBytes
                path      = "$PathPrefix/$SafeName"
            }
        }
    }
    catch {
        # Jamais fatal : on conserve ce qui a ete capture jusqu'ici.
    }
    return @{ Captured = @($CapturedFiles); Skipped = @($SkippedFiles) }
}
