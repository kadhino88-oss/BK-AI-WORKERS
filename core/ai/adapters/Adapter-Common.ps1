# =====================================================================
# BK-AI-WORKERS - Fonctions communes des adaptateurs Anthropic (extraites de ANTHROPIC-ADAPTER.ps1, 2026-10-19).
#
# Extraction MECANIQUE, sans changement de comportement : ces fonctions servaient deja a la boucle de mission de
# ANTHROPIC-ADAPTER.ps1 ; elles sont maintenant partagees avec la boucle d'une ETAPE DE PROJET (Project-Loop.ps1, docs/AUTONOMY-ENGINE.md,
# section 3.2). A dot-sourcer depuis un script qui definit $ProjectRoot (la racine du depot) et qui a deja charge Connector-Dispatch.ps1
# ($Script:OperationTable).
# =====================================================================

# =====================================================================
# OUTIL "use_connector" — construit dynamiquement a partir des SEULS
# connecteurs que CE client a actives pour son compte (jamais tous les
# connecteurs du catalogue), et des operations reellement cablees dans
# Connector-Dispatch.ps1. Si le client n'a rien active, pas d'outil du
# tout : Claude repond en texte, comme avant.
# =====================================================================

# Description courte, par operation, des parametres attendus — guide
# textuel plutot qu'un schema JSON par operation (varierait trop d'un
# connecteur a l'autre) : suffisant pour un modele, et evite de
# dupliquer la table de Connector-Dispatch.ps1 ici.
$Script:OperationParamHints = @{
    "gmail:DRAFT_MESSAGE" = "To, Subject, Body"
    "gmail:SEARCH_MESSAGES" = "Query"
    "outlook_mail:DRAFT_MESSAGE" = "To, Subject, Body"
    "outlook_mail:SEARCH_MESSAGES" = "Query"
    "calendar:CREATE_EVENT" = "Summary, StartIso, EndIso"
    "calendar:SEARCH_EVENTS" = "Query"
    "outlook_calendar:CREATE_EVENT" = "Summary, StartIso, EndIso"
    "outlook_calendar:SEARCH_EVENTS" = "Query"
    "salesforce:SEARCH_CONTACTS" = "Query"
    "salesforce:READ_CONTACT" = "Id"
    "salesforce:READ_OPPORTUNITY" = "Id"
    "salesforce:CREATE_TASK" = "Subject, Notes"
    "hubspot:SEARCH_CONTACTS" = "Query"
    "hubspot:READ_CONTACT" = "Id"
    "hubspot:READ_DEAL" = "Id"
    "hubspot:CREATE_TASK" = "Subject, Notes"
    "pipedrive:SEARCH_CONTACTS" = "Query"
    "pipedrive:READ_CONTACT" = "Id"
    "pipedrive:READ_DEAL" = "Id"
    "linkedin:CREATE_DRAFT_POST" = "Text"
    "instagram:CREATE_DRAFT_POST" = "Text, IgUserId"
    "facebook:CREATE_DRAFT_POST" = "Text, PageId"
    "facebook:READ_POSTS" = "PageId"
    "tiktok:CREATE_DRAFT_POST" = "Text"
    "x_twitter:CREATE_DRAFT_POST" = "Text"
    "wordpress:CREATE_DRAFT" = "Title, Content"
    "wordpress:UPDATE_DRAFT" = "Id, Title, Content"
    "webflow:UPDATE_DRAFT" = "Id, Title"
    "shopify:READ_PRODUCT" = "Id"
    "shopify:READ_INVENTORY" = "Id"
    "woocommerce:READ_PRODUCT" = "Id"
    "teams:DRAFT_MESSAGE" = "TeamId, ChannelId, Text"
    "whatsapp_business:DRAFT_MESSAGE" = "PhoneNumberId, Text"
    "google_drive:SEARCH_FILES" = "Query"
    "google_drive:READ_FILE" = "Id"
    "dropbox:SEARCH_FILES" = "Query"
    "dropbox:READ_FILE" = "Path"
    "onedrive:SEARCH_FILES" = "Query"
    "onedrive:READ_FILE" = "Id"
    "google_search_console:READ_REPORT" = "SiteUrl, StartDate, EndDate"
    "google_search_console:SEARCH_QUERIES" = "SiteUrl, StartDate, EndDate"
    "google_ads:READ_CAMPAIGN" = "CustomerId"
    "google_ads:READ_REPORT" = "CustomerId"
    "meta_ads:READ_CAMPAIGN" = "AdAccountId"
    "meta_ads:READ_REPORT" = "CampaignId"
    "asana:SEARCH_TASKS" = "WorkspaceGid, Query"
    "asana:READ_TASK" = "Id"
    "asana:CREATE_TASK" = "Name, Notes, WorkspaceGid"
    "trello:SEARCH_CARDS" = "Query"
    "trello:READ_CARD" = "Id"
    "trello:CREATE_CARD" = "Name, Description, ListId"
    "monday:SEARCH_ITEMS" = "BoardId"
    "monday:READ_ITEM" = "Id"
    "monday:CREATE_ITEM" = "BoardId, Name"
    "zendesk:SEARCH_TICKETS" = "Query"
    "zendesk:READ_TICKET" = "Id"
    "zendesk:DRAFT_REPLY" = "Id, Body"
    "intercom:SEARCH_TICKETS" = "Query"
    "intercom:READ_TICKET" = "Id"
    "intercom:DRAFT_REPLY" = "Id, Body, AdminId"
    "figma:READ_ASSET" = "FileKey"
    "figma:SEARCH_ASSETS" = "FileKey"
    "monitoring:READ_STATUS" = "(aucun parametre)"
    "monitoring:SEARCH_INCIDENTS" = "(aucun parametre)"
    "calendar_hr:READ_EMPLOYEE_RECORD" = "Id"
    "calendar_hr:SEARCH_CANDIDATES" = "(aucun parametre)"
    "slack:POST_MESSAGE" = "Text, WorkerName"
    "twilio:PLACE_CALL" = "To (numero E.164, ex: +41791234567), Message (texte que le Worker doit dire au telephone, en langage naturel)"
    "slack:DRAFT_MESSAGE" = "Text"
    "stripe:READ_CUSTOMER" = "Id"
    "stripe:CREATE_REFUND" = "ChargeId, Amount (optionnel, en centimes — total si omis)"
    "stripe:CREATE_PAYOUT" = "Amount (en centimes), Currency"
    "paypal:CREATE_REFUND" = "CaptureId, Amount, Currency"
    "paypal:CREATE_PAYOUT" = "Amount, Currency, Receiver (email du destinataire)"
    "quickbooks:READ_COMPANY_INFO" = "Id"
    "quickbooks:CREATE_PAYMENT" = "Amount, CustomerId"
    "xero:CREATE_PAYMENT" = "InvoiceId, AccountCode, Amount"
}

function Get-ClientActivatedConnectors {
    param([string]$ClientId)
    $Path = Join-Path $ProjectRoot ("core/connectors/data/" + $ClientId + ".json")
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    try {
        $Ids = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return @($Ids | ForEach-Object { $_ -replace '\.controlled$', '' })
    } catch { return @() }
}

function Test-ClientAutoApprove {
    <#
    Pre-autorisation globale, choix explicite et reversible du client
    (bascule dans son tableau de bord) : quand vraie, une action
    d'ecriture proposee par ce Worker s'execute pour de vrai tout de
    suite, sans carte de confirmation manuelle. Faux par defaut — un
    fichier absent ou illisible ne doit jamais etre interprete comme une
    autorisation.
    #>
    param([string]$ClientId)
    $Path = Join-Path $ProjectRoot ("core/connectors/data/" + $ClientId + ".autoapprove.json")
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $Cfg = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [bool]$Cfg.autoApprove
    } catch { return $false }
}

function Build-ConnectorToolDefinition {
    param([string]$ClientId)

    # @() autour de l'appel est obligatoire : une fonction qui "retourne"
    # un tableau a un seul element est deballee en simple chaine par le
    # pipeline PowerShell (meme piege que Save-Automations plus tot dans
    # ce projet) — sans ce garde-fou, $Activated.Count plante des qu'un
    # client n'a active qu'UN SEUL connecteur.
    $Activated = @(Get-ClientActivatedConnectors -ClientId $ClientId)
    if ($Activated.Count -eq 0) { return $null }

    $Lines = @()
    foreach ($ConnId in $Activated) {
        if ($ConnId -eq "slack") {
            $Lines += "- slack : SEARCH_MESSAGES, DRAFT_MESSAGE (prepare), POST_MESSAGE (envoie reellement, params: Text)"
            continue
        }
        if ($ConnId -eq "twilio") {
            $Lines += "- twilio : PLACE_CALL (place un vrai appel telephonique, params: To, Message)"
            continue
        }
        $Entry = $Script:OperationTable[$ConnId]
        if (-not $Entry) { continue }
        $OpsDesc = @($Entry.Operations.Keys | ForEach-Object {
            $Hint = $Script:OperationParamHints["${ConnId}:$_"]
            if ($Hint) { "$_ (params: $Hint)" } else { $_ }
        }) -join ", "
        $Lines += "- ${ConnId} : $OpsDesc"
    }
    if ($Lines.Count -eq 0) { return $null }

    return @{
        name = "use_connector"
        description = "Consulte ou prepare une action reelle via un outil externe QUE LE CLIENT A LUI-MEME CONNECTE a son compte. N'utilise que les connecteurs et operations listes ici, avec exactement les parametres indiques (en 'params'). Connecteurs disponibles pour ce client :`n" + ($Lines -join "`n") + "`n`nLes operations READ_*/SEARCH_* consultent une vraie donnee et te reviennent immediatement. Les autres (DRAFT_*/CREATE_*/POST_*/UPDATE_*/PREPARE_*/DRAFT_REPLY) preparent une action reelle mais NE PARTENT JAMAIS automatiquement — le client doit confirmer lui-meme depuis son tableau de bord avant tout envoi effectif."
        input_schema = @{
            type = "object"
            properties = @{
                connectorId = @{ type = "string"; description = "Identifiant exact du connecteur, ex: trello, gmail, hubspot" }
                operation   = @{ type = "string"; description = "Operation exacte, ex: SEARCH_CARDS, CREATE_TASK" }
                params      = @{ type = "object"; description = "Parametres attendus par cette operation (voir la liste ci-dessus)" }
                reason      = @{ type = "string"; description = "Une phrase expliquant pourquoi cette action aide a repondre a la mission" }
            }
            required = @("connectorId", "operation", "reason")
        }
    }
}

function Test-ReadOnlyOperation {
    param([string]$Operation)
    return ($Operation -like "READ_*" -or $Operation -like "SEARCH_*")
}

# Auto-approve ("Laisser mes Workers agir seuls") ne vaut QUE pour les vrais brouillons : rien ne part chez un tiers.
# Attention aux noms trompeurs : CREATE_DRAFT_POST PUBLIE sur LinkedIn/Facebook/X/TikTok/Instagram, et DRAFT_MESSAGE
# ENVOIE vraiment sur Teams/WhatsApp (revue 2026-10-11). BK_AUTOAPPROVE_DRAFTS_ONLY=0 restaure l'ancien comportement.
$AutoApproveSafeOps = @("gmail|DRAFT_MESSAGE", "outlook_mail|DRAFT_MESSAGE", "wordpress|CREATE_DRAFT", "wordpress|UPDATE_DRAFT", "zendesk|DRAFT_REPLY", "intercom|DRAFT_REPLY")

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
