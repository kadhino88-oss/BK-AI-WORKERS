# =====================================================================
# BK-AI-WORKERS - Outil "use_connector" et garde-fou d'approbation, PARTAGES par tous les adaptateurs de moteurs
# (ANTHROPIC-ADAPTER.ps1 et OPENAI-COMPAT-ADAPTER.ps1). Extrait le 2026-10-25 de ANTHROPIC-ADAPTER.ps1 SANS changer son comportement :
# les memes fonctions, le meme texte, une seule implementation de la regle « un Worker prepare, il n'envoie jamais seul ».
# A dot-sourcer APRES avoir defini $ProjectRoot et charge Connector-Dispatch.ps1 ($Script:OperationTable, Invoke-ConnectorAction).
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

function Invoke-BKConnectorToolCall {
    <#
    Decision UNIQUE pour un appel de l'outil use_connector, quel que soit le moteur qui l'a demande (Claude, modele local, hote suisse) :
      - lecture (READ_* / SEARCH_*) : executee reellement tout de suite ;
      - ecriture : JAMAIS executee ici, ecrite dans memory/runtime/PENDING-ACTION-<TaskId>.json pour confirmation explicite du client
        (POST /api/connector-action/confirm), sauf pre-autorisation du client limitee aux vrais brouillons ($AutoApproveSafeOps) ;
      - sortie d'argent depuis le compte du proprietaire (CLI-DASHBOARD) : toujours confirmation manuelle ;
      - installation du Worker en pause : plus d'action seule.
    -Strict (moteurs sans l'entrainement de Claude a l'usage d'outils) : le connecteur DOIT faire partie de ceux que le client a actives et
    l'operation DOIT exister dans la table de Connector-Dispatch.ps1 ; sinon refus avant tout appel. Les arguments viennent du modele : donnees, jamais ordres.
    Renvoie { Content = texte du resultat d'outil ; Action = entree pour connector_actions ; Stop = $true si la boucle doit s'arreter }.
    #>
    param(
        [string]$ClientId, [string]$WorkerId, [string]$TaskId,
        [string]$ConnId, [string]$Op, [string]$Reason, $OpParams,
        [switch]$Strict
    )
    if ($null -eq $OpParams) { $OpParams = @{} }

    if ($Strict) {
        $Active = @(Get-ClientActivatedConnectors -ClientId $ClientId)
        $BaseId = Get-ConnectorBaseId -ConnectorId "$ConnId.controlled"
        $KnownOp = $false
        if ($BaseId -eq "slack") { $KnownOp = ($Op -in @("SEARCH_MESSAGES", "DRAFT_MESSAGE", "POST_MESSAGE")) }
        elseif ($BaseId -eq "twilio") { $KnownOp = ($Op -eq "PLACE_CALL") }
        elseif ($Script:OperationTable[$BaseId]) { $KnownOp = [bool]$Script:OperationTable[$BaseId].Operations[$Op] }
        if (($Active -notcontains $BaseId) -or -not $KnownOp -or $ConnId -cnotmatch '^[a-z0-9_]{2,40}$' -or $Op -cnotmatch '^[A-Z_]{3,40}$') {
            return [pscustomobject]@{
                Content = "REFUSE : ce connecteur ou cette operation n'est pas disponible pour ce client. Utilise uniquement ceux de la liste de l'outil."
                Action  = @{ connectorId = $ConnId; operation = $Op; status = "REFUSED"; executed = $false }
                Stop    = $false
            }
        }
    }

    $AutoApproved = Test-ClientAutoApprove -ClientId $ClientId
    # Garde-fou specifique a Kader (CLI-DASHBOARD) : sur SON PROPRE
    # compte, une sortie d'argent (connecteur financier, operation
    # non READ_*/SEARCH_*) exige TOUJOURS sa confirmation manuelle,
    # meme s'il a active "auto-approve" pour le reste — regle
    # explicite, sans exception, distincte du choix d'un client sur
    # son propre portefeuille (celui-la reste regi par son propre
    # bascule auto-approve, comme n'importe quel autre connecteur).
    $IsFinancialConnector = (Get-ConnectorBaseId -ConnectorId "$ConnId.controlled") -in @("stripe", "paypal", "quickbooks", "xero")
    if ($ClientId -eq "CLI-DASHBOARD" -and $IsFinancialConnector -and -not (Test-ReadOnlyOperation -Operation $Op)) {
        $AutoApproved = $false
    }
    if ($AutoApproved -and $env:BK_AUTOAPPROVE_DRAFTS_ONLY -ne "0" -and -not (Test-ReadOnlyOperation -Operation $Op) -and (("$ConnId|$Op") -notin $AutoApproveSafeOps)) {
        $AutoApproved = $false
    }
    # Interrupteur d'arret (2026-10-12) : le client a mis l'installation de CE Worker en pause -> il n'agit plus seul, meme pour un vrai
    # brouillon (il attend la confirmation du client). La mission lancee a la main fonctionne toujours : lectures et propositions restent possibles.
    if ($AutoApproved -and (Test-BKInstallationPaused -Root $ProjectRoot -ClientId $ClientId -WorkerId $WorkerId)) {
        $AutoApproved = $false
    }

    if ((Test-ReadOnlyOperation -Operation $Op) -or $AutoApproved) {
        # Lecture : toujours executee reellement tout de suite
        # (aucun effet externe possible). Ecriture : executee
        # reellement tout de suite UNIQUEMENT si ce client a
        # explicitement pre-autorise ses Workers a agir sans
        # attendre (bascule "autoApprove", desactivee par defaut).
        $ActionResult = Invoke-ConnectorAction -ConnectorId "$ConnId.controlled" -Operation $Op -ClientId $ClientId -Params $OpParams
        return [pscustomobject]@{
            Content = ($ActionResult | ConvertTo-Json -Depth 10 -Compress)
            Action  = @{ connectorId = $ConnId; operation = $Op; status = $ActionResult.Status; executed = $true; autoApproved = $AutoApproved }
            Stop    = $false
        }
    }

    # Ecriture : JAMAIS executee ici. On ecrit l'action proposee
    # sur disque pour confirmation explicite du client. Une
    # seule action en attente possible par mission (le fichier
    # est nomme par TaskId, pas par tool_use.id) : la premiere
    # ecriture non auto-approuvee arrete la boucle apres ce
    # tour, pour ne jamais en ecraser une deuxieme.
    $PendingPath = Join-Path $ProjectRoot ("memory/runtime/PENDING-ACTION-" + $TaskId + ".json")
    $Pending = [ordered]@{
        taskId       = $TaskId
        clientId     = $ClientId
        workerId     = $WorkerId
        connectorId  = $ConnId
        operation    = $Op
        params       = $OpParams
        reason       = $Reason
        createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    }
    ($Pending | ConvertTo-Json -Depth 10) | Set-Content -LiteralPath $PendingPath -Encoding UTF8
    return [pscustomobject]@{
        Content = "PENDING_CONFIRMATION : action non executee, en attente de confirmation du client depuis son tableau de bord."
        Action  = @{ connectorId = $ConnId; operation = $Op; status = "PENDING_CONFIRMATION"; executed = $false }
        Stop    = $true
    }
}
