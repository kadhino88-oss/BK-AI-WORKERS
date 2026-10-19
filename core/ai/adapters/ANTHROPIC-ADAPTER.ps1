# ============================================================
# BK AI WORKERS
# ANTHROPIC ADAPTER — appel reel (API Messages, Claude)
# Remplace le stub (qui ne faisait jamais d'appel reseau). Meme
# principe que OPENAI-ADAPTER.ps1 : la cle DPAPI
# (.secrets\anthropic.secret.dpapi, stockee par Kader lui-meme via
# Store-Credential.ps1) est dechiffree en memoire UNIQUEMENT le temps
# de l'appel HTTP, jamais journalisee, effacee juste apres.
#
# 2026-09-23 : ajout de l'usage d'outils (tool use) cote Claude, pour
# que les Workers puissent reellement consulter ou preparer une action
# via un connecteur QUE LE CLIENT A LUI-MEME ACTIVE pour son compte
# (voir core/connectors/data/<ClientId>.json, active depuis le
# dashboard). Deux comportements distincts selon l'operation demandee :
#   - lecture (READ_*/SEARCH_*) : executee reellement tout de suite
#     (aucun effet externe possible, juste consulter une donnee que le
#     client a explicitement connectee) — un second aller-retour Claude
#     integre le resultat dans la reponse finale.
#   - ecriture (DRAFT_*/CREATE_*/POST_*/UPDATE_*/PREPARE_*/DRAFT_REPLY) :
#     JAMAIS executee automatiquement ici. L'action proposee est ecrite
#     dans memory/runtime/PENDING-ACTION-<TaskId>.json ; seule une
#     confirmation explicite du client (POST /api/connector-action/
#     confirm, cote dashboard) declenche le vrai appel, via
#     core/integrations/Connector-Dispatch.ps1. Meme principe que le
#     reste de la plateforme depuis le debut : un Worker prepare, il
#     n'envoie jamais seul.
#
# 2026-10-12 : PLAFOND DE COUT PAR MISSION (Mission-Cost.ps1, tarifs
# dans core/ai/AI-PRICING.json, plafond maxCostChf par niveau dans
# core/ai/LEVELS.json). Le cout reel de chaque appel est cumule
# (jetons, cache, recherches web) ; la boucle s'arrete AVANT l'appel
# qui ferait depasser le plafond et rend la meilleure reponse obtenue
# + une note en francais + cost_capped=true. usage porte les jetons
# cumules et le cout estime (estimated_cost_usd / estimated_cost_chf).
# ============================================================

param(
    [Parameter(Mandatory=$true)][string]$ClientId,
    [Parameter(Mandatory=$true)][string]$ProjectId,
    [Parameter(Mandatory=$true)][string]$WorkerId,
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$true)][string]$Objective,
    [Parameter(Mandatory=$false)][string]$Model = "NONE"
)

$ErrorActionPreference = "Stop"
# Herite parfois Set-StrictMode -Version Latest de la chaine appelante
# (AI-SECURE-ENTRY-GUARD.ps1) : sous ce mode, l'acces en notation point a
# une cle de hashtable/parametre absente leve une exception (ex : $P.To
# quand l'IA n'a pas fourni "To"), au lieu de renvoyer $null comme
# attendu partout dans ce fichier. Desactive explicitement.
Set-StrictMode -Off
$ProjectRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $ProjectRoot "core/ai/BK-Secret.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Build-WorkerSystemPrompt.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Get-RecentConversation.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Client-Memory.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Client-Installation.ps1")
. (Join-Path $ProjectRoot "core/ai/adapters/Mission-Cost.ps1")
. (Join-Path $ProjectRoot "core/integrations/Connector-Dispatch.ps1")

# Modele : celui demande, sinon celui de AI-PROVIDERS.json, sinon Haiku 4.5.
$EffectiveModel = $Model
if ([string]::IsNullOrWhiteSpace($EffectiveModel) -or $EffectiveModel -eq "NONE") {
    $EffectiveModel = "claude-haiku-4-5-20251001"
    try {
        $Cfg = Get-Content -LiteralPath (Join-Path $ProjectRoot "core/ai/AI-PROVIDERS.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($Cfg.providers.anthropic.model) { $EffectiveModel = [string]$Cfg.providers.anthropic.model }
    } catch { }
}

# Niveau de travail de la mission (Rapide / Equilibre / Approfondi) : modele, effort, etapes, recherches, delai (core/ai/LEVELS.json).
$LevelCfg = $null
if ($env:BK_MISSION_LEVEL -match '^[a-z]{3,20}$') {
    try {
        $AllLevels = Get-Content -LiteralPath (Join-Path $ProjectRoot "core/ai/LEVELS.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $LevelProp = $AllLevels.levels.PSObject.Properties[$env:BK_MISSION_LEVEL]
        if ($LevelProp) { $LevelCfg = $LevelProp.Value }
    } catch { $LevelCfg = $null }
}
if ($LevelCfg -and $LevelCfg.model) { $EffectiveModel = [string]$LevelCfg.model }
$WebMaxUses = if ($LevelCfg -and $LevelCfg.webMaxUses) { [int]$LevelCfg.webMaxUses } else { 5 }
$CallTimeout = if ($LevelCfg -and $LevelCfg.callTimeoutSec) { [int]$LevelCfg.callTimeoutSec } else { 240 }
# output_config.effort : GA sur les modeles 5.x, PAS sur Haiku 4.5 (le modele historique des Workers).
$UseEffort = ($LevelCfg -and $LevelCfg.effort -and $EffectiveModel -notlike "claude-haiku-4*")
$MissionDeadline = (Get-Date).AddSeconds($(if ($env:BK_MISSION_DEADLINE_SEC -match '^[0-9]{2,3}$' -and [int]$env:BK_MISSION_DEADLINE_SEC -le 540) { [int]$env:BK_MISSION_DEADLINE_SEC } else { 540 }))   # le serveur coupe a 600 s : on rend un resultat partiel avant (Chloe donne un delai plus court a chaque Worker d'une mission multi-Workers : BK_MISSION_DEADLINE_SEC)
# Plafond de cout de la mission (maxCostChf du niveau) et suivi du cout reel appel par appel : Mission-Cost.ps1, tarifs dans
# core/ai/AI-PRICING.json. Sans niveau (ancien comportement) ou pour Rapide : pas de plafond, le cout est quand meme releve.
$CostCeilingChf = if ($LevelCfg) { $LevelCfg.maxCostChf } else { $null }
$MissionCost = New-BKMissionCost -Pricing (Get-BKPricing -Root $ProjectRoot) -Model $EffectiveModel -CeilingChf $CostCeilingChf

Write-Host "ANTHROPIC ADAPTER | worker=$WorkerId | model=$EffectiveModel"

function Write-Result($Object) { $Object | ConvertTo-Json -Depth 10 -Compress }

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

$PlainKey = $null
$ResponseText = $null; $ErrorDetail = $null; $ExitCode = 1
$Response = $null

if (-not (Test-BKSecret -Name "anthropic")) {
    Write-Result ([ordered]@{ status="ERROR"; provider="anthropic"; model=$EffectiveModel; mode="SIMULATION"; api_call=$false; answer=""; error="CREDENTIAL_NOT_CONFIGURED" })
    exit 1
}

try {
    $PlainKey = Get-BKSecretValue -Name "anthropic"
    if ([string]::IsNullOrWhiteSpace($PlainKey)) { throw "CREDENTIAL_EMPTY" }

    $SystemPrompt = Get-WorkerSystemPrompt -WorkerId $WorkerId -ClientId $ClientId
    # Indice de capture de fichiers (2026-10-08) : si le modele produit un
    # livrable (Excel/Word/PDF/CSV/image) via code execution, il doit
    # l'ecrire dans le repertoire $OUTPUT_DIR de l'environnement d'execution
    # pour qu'il soit capture et propose au telechargement. Simple ajout de
    # chaine sur la variable locale (sans risque pour le chemin critique).
    if (-not [string]::IsNullOrWhiteSpace($SystemPrompt)) {
        $SystemPrompt = [string]$SystemPrompt + "`n`nSi tu produis un fichier livrable (Excel, Word, PDF, CSV, image) via l'outil d'execution de code, ecris-le ou copie-le dans le repertoire `$OUTPUT_DIR de l'environnement d'execution afin qu'il soit capture et mis a disposition pour telechargement."
    }
    $SystemBlocks = @(@{ type = "text"; text = [string]$SystemPrompt; cache_control = @{ type = "ephemeral" } })
    $ToolDef = Build-ConnectorToolDefinition -ClientId $ClientId
    # Outil "memory" : memoire durable et archive illimitee de CE client (Client-Memory.ps1) ; absent pour l'essai public.
    $MemoryToolDef = if (Get-BKMemoryDir -Root $ProjectRoot -ClientId $ClientId) { Get-BKMemoryToolDefinition } else { $null }
    $Messages = [System.Collections.ArrayList]@()
    foreach ($Turn in (Get-BKRecentConversationTurns -Root $ProjectRoot -ClientId $ClientId -WorkerId $WorkerId)) {
        [void]$Messages.Add($Turn)
    }
    [void]$Messages.Add(@{ role = "user"; content = $Objective })

    # Recherche/lecture web reelles (2026-09-30, demande explicite de Kader :
    # "tous mes agents doivent etre capables de chercher... comme Claude Code
    # le fait"). Outils SERVEUR Anthropic (web_search/web_fetch) : Claude
    # decide seul quand les utiliser, l'execution se fait cote Anthropic dans
    # le MEME appel (stop_reason reste "end_turn", aucun aller-retour
    # supplementaire a gerer ici, verifie en direct le 2026-09-30). Toujours
    # disponibles, independamment des connecteurs metier actives par le
    # client — ce n'est pas un connecteur au sens Chloe, juste la capacite
    # de lire une page publique, deja implicitement couverte par "READ".
    # Code execution reel (2026-09-30, meme demande que web_search/web_fetch :
    # "les Workers doivent avoir tout dans leur code, comme Claude Code").
    # Outil SERVEUR lui aussi (resolu par Anthropic dans le meme appel),
    # mais necessite l'entete beta ci-dessous — verifie en direct.
    # Deux variantes d'outils + entetes (2026-10-08) :
    #   NEW (preferee) : code_execution_20250825, qui ne requiert PLUS
    #     l'entete beta 'code-execution-2025-05-22'.
    #   OLD (prod connue-bonne) : exactement la config d'avant
    #     (code_execution_20250522 + l'entete beta).
    # On tente NEW au premier POST ; si l'API la rejette (modele/compte),
    # on bascule sur OLD et on rejoue CE POST une seule fois. La variante
    # qui reussit ($Tools/$Headers) est reutilisee pour toute la boucle,
    # ce qui garantit que le chemin critique ne regresse jamais sous le
    # comportement d'aujourd'hui. Si les DEUX echouent, l'exception remonte
    # au catch principal (aucune erreur reelle n'est avalee).
    $ToolsNew = @(
        @{ type = "web_search_20250305"; name = "web_search"; max_uses = $WebMaxUses }
        @{ type = "web_fetch_20250910"; name = "web_fetch"; max_uses = $WebMaxUses }
        @{ type = "code_execution_20250825"; name = "code_execution" }
    )
    $ToolsOld = @(
        @{ type = "web_search_20250305"; name = "web_search"; max_uses = $WebMaxUses }
        @{ type = "web_fetch_20250910"; name = "web_fetch"; max_uses = $WebMaxUses }
        @{ type = "code_execution_20250522"; name = "code_execution" }
    )
    if ($ToolDef) { $ToolsNew += $ToolDef; $ToolsOld += $ToolDef }
    if ($MemoryToolDef) { $ToolsNew += $MemoryToolDef; $ToolsOld += $MemoryToolDef }

    $HeadersNew = @{
        "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01"
    }
    $HeadersOld = @{
        "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01"
        "anthropic-beta" = "code-execution-2025-05-22"
    }

    $Tools = $ToolsNew
    $Headers = $HeadersNew
    try {
        $BodyObj = [ordered]@{
            model = $EffectiveModel; max_tokens = 64000; system = $SystemBlocks; messages = $Messages; tools = $Tools
        }
        if ($UseEffort) { $BodyObj["output_config"] = @{ effort = [string]$LevelCfg.effort } }
        $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
            -Headers $Headers -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($BodyObj | ConvertTo-Json -Depth 10))) -TimeoutSec $CallTimeout
    }
    catch {
        # Repli UNIQUEMENT si l'API refuse la version d'outil (HTTP 400 qui parle d'outil / beta). Timeout, 429, 5xx,
        # contexte trop long... : on remonte l'erreur (sinon on paierait deux generations et ~480 s avant la boucle).
        $FallbackStatus = 0
        try { $FallbackStatus = [int]$_.Exception.Response.StatusCode } catch { }
        $FallbackText = ([string]$_.ErrorDetails.Message) + " " + ([string]$_.Exception.Message)
        if (-not ($FallbackStatus -eq 400 -and $FallbackText -match 'tool|beta|code_execution|web_fetch|web_search')) { throw }
        $Tools = $ToolsOld
        $Headers = $HeadersOld
        $BodyObj = [ordered]@{
            model = $EffectiveModel; max_tokens = 64000; system = $SystemBlocks; messages = $Messages; tools = $Tools
        }
        if ($UseEffort) { $BodyObj["output_config"] = @{ effort = [string]$LevelCfg.effort } }
        $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
            -Headers $Headers -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($BodyObj | ConvertTo-Json -Depth 10))) -TimeoutSec $CallTimeout
    }

    # Cout du premier appel (un POST refuse par l'API, comme le repli d'outil ci-dessus, n'est pas facture et n'est pas compte).
    Add-BKCallCost -Cost $MissionCost -Response $Response
    $LastNonEmptyText = Get-ResponseText -Resp $Response   # meilleure reponse obtenue jusqu'ici (arret au plafond de cout)

    # ---------------- BOUCLE AGENTIQUE (2026-09-30) ----------------
    # Avant : un SEUL aller-retour possible pour use_connector (le Worker
    # ne pouvait jamais enchainer deux actions dans la meme mission —
    # regarder un CRM PUIS agir dessus etait impossible). Demande
    # explicite de Kader : "les Workers doivent pouvoir tout faire en
    # autonomie... comme Claude Code", donc une vraie boucle, plafonnee
    # (MaxIterations) pour rester bornee en cout/latence — jamais
    # illimitee. web_search/web_fetch/code_execution restent geres cote
    # Anthropic a chaque tour (jamais un "tool_use" cote client) : cette
    # boucle ne s'occupe que de use_connector, le seul outil qui a besoin
    # de CE code pour s'executer.
    $ConnectorActionsList = @()
    $AllFileIds = @(Get-CodeExecFileIds -Resp $Response)
    $MaxIterations = if ($LevelCfg -and $LevelCfg.maxIterations) { [int]$LevelCfg.maxIterations } else { 8 }
    $Iteration = 0
    $StopLoop = $false
    $CostStopFrom = 0   # indice, dans $ConnectorActionsList, des actions du DERNIER tour (note d'arret au plafond de cout)

    while (($Response.stop_reason -eq "tool_use" -or $Response.stop_reason -eq "pause_turn") -and $Iteration -lt $MaxIterations -and -not $StopLoop -and (Get-Date) -lt $MissionDeadline) {
        $Iteration++
        $TurnActionsStart = $ConnectorActionsList.Count
        $ToolUses = @($Response.content | Where-Object { $_.type -eq "tool_use" })
        if ($ToolUses.Count -eq 0 -and $Response.stop_reason -ne "pause_turn") { break }   # pause_turn : on reprend le tour des outils serveur tel quel

        [void]$Messages.Add(@{ role = "assistant"; content = $Response.content })
        $ToolResults = @()

        foreach ($ToolUse in $ToolUses) {
            if ([string]$ToolUse.name -eq "memory") {
                # Memoire du client : executee ici (lecture/ecriture de SON dossier uniquement), aucune validation humaine requise.
                $MemOut = Invoke-BKMemoryTool -Root $ProjectRoot -ClientId $ClientId -ToolInput $ToolUse.input
                $ToolResults += @{ type = "tool_result"; tool_use_id = $ToolUse.id; content = [string]$MemOut }
                continue
            }
            $ConnId = [string]$ToolUse.input.connectorId
            $Op     = [string]$ToolUse.input.operation
            $Reason = [string]$ToolUse.input.reason
            $OpParams = @{}
            if ($ToolUse.input.params) {
                $ToolUse.input.params.PSObject.Properties | ForEach-Object { $OpParams[$_.Name] = $_.Value }
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
                $ConnectorActionsList += @{ connectorId = $ConnId; operation = $Op; status = $ActionResult.Status; executed = $true; autoApproved = $AutoApproved }
                $ToolResults += @{ type = "tool_result"; tool_use_id = $ToolUse.id; content = ($ActionResult | ConvertTo-Json -Depth 10 -Compress) }
            }
            else {
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

                $ConnectorActionsList += @{ connectorId = $ConnId; operation = $Op; status = "PENDING_CONFIRMATION"; executed = $false }
                $ToolResults += @{ type = "tool_result"; tool_use_id = $ToolUse.id; content = "PENDING_CONFIRMATION : action non executee, en attente de confirmation du client depuis son tableau de bord." }
                $StopLoop = $true
            }
        }

        if ($ToolResults.Count -gt 0) { [void]$Messages.Add(@{ role = "user"; content = $ToolResults }) }

        # PLAFOND DE COUT PAR MISSION (2026-10-12, etude de marche 4.1) : on ne lance pas l'appel suivant s'il fait depasser le
        # plafond du niveau. Les outils de ce tour sont deja traites ci-dessus : une action en attente de confirmation reste
        # ecrite sur disque et listee dans connector_actions. Resultat : meilleure reponse obtenue + note + cost_capped.
        if ($MissionCost.CeilingChf) {
            $NewChars = 0
            foreach ($TR in $ToolResults) { $NewChars += ([string]$TR.content).Length }
            foreach ($Blk in @($Response.content)) {   # resultats d'outils serveur (recherche web, code) : renvoyes dans le prompt suivant
                if ($Blk -and ([string]$Blk.type) -like '*_tool_result') { $NewChars += ($Blk | ConvertTo-Json -Depth 12 -Compress).Length }
            }
            $CostGate = Test-BKCostGate -Cost $MissionCost -NewChars $NewChars
            if ($CostGate.Stop) {
                $MissionCost.Capped = $true
                $MissionCost.CapReason = [string]$CostGate.Reason
                $CostStopFrom = $TurnActionsStart
                Write-Host ("COST CEILING | stop before call #" + ($MissionCost.Calls + 1) + " | " + $CostGate.Reason)
                break
            }
        }

        $BodyObjN = [ordered]@{
            model = $EffectiveModel; max_tokens = 64000; system = $SystemBlocks; messages = $Messages
            tools = $Tools
        }
        if ($UseEffort) { $BodyObjN["output_config"] = @{ effort = [string]$LevelCfg.effort } }
        $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
            -Headers $Headers -ContentType "application/json; charset=utf-8" `
            -Body ([System.Text.Encoding]::UTF8.GetBytes(($BodyObjN | ConvertTo-Json -Depth 10))) -TimeoutSec ([int][Math]::Max(30, [Math]::Min($CallTimeout, ($MissionDeadline - (Get-Date)).TotalSeconds)))
        $AllFileIds += @(Get-CodeExecFileIds -Resp $Response)
        Add-BKCallCost -Cost $MissionCost -Response $Response
        $TurnText = Get-ResponseText -Resp $Response
        if (-not [string]::IsNullOrWhiteSpace($TurnText)) { $LastNonEmptyText = $TurnText }
    }

    $ResponseText = Get-ResponseText -Resp $Response
    if ($MissionCost.Capped) {
        # Arret au plafond de cout : la meilleure reponse obtenue (celle du dernier tour, sinon la derniere non vide), puis une
        # note qui dit ce qu'il reste a faire. Les actions en attente restent valides (fichier PENDING-ACTION + connector_actions).
        if ([string]::IsNullOrWhiteSpace($ResponseText)) { $ResponseText = $LastNonEmptyText }
        $PendingForNote = @($ConnectorActionsList | Where-Object { $_.status -eq "PENDING_CONFIRMATION" })
        # Lectures du dernier tour dont le modele n'a jamais vu le resultat (les brouillons auto-approuves, eux, sont des actions faites).
        $UnusedReadsForNote = @($ConnectorActionsList | Select-Object -Skip $CostStopFrom | Where-Object { $_.executed -and (Test-ReadOnlyOperation -Operation ([string]$_.operation)) })
        $CostNote = Get-BKCostCapNote -PendingActions $PendingForNote -UnusedReads $UnusedReadsForNote -FileCount @($AllFileIds | Select-Object -Unique).Count
        $ResponseText = (([string]$ResponseText).Trim() + "`n`n" + $CostNote).Trim()
    }
    else {
        if ([string]::IsNullOrWhiteSpace($ResponseText) -and ($Response.stop_reason -eq "tool_use" -or $Response.stop_reason -eq "pause_turn")) {
            $ResponseText = "La mission a atteint sa duree ou son nombre d'etapes maximum avant de conclure. Ecrivez « continue » : je reprends exactement la ou je me suis arretee, avec ce qui est deja fait."
        }
        if ([string]::IsNullOrWhiteSpace($ResponseText) -and $ConnectorActionsList.Count -gt 0) {
            $LastPending = $ConnectorActionsList | Where-Object { $_.status -eq "PENDING_CONFIRMATION" } | Select-Object -Last 1
            if ($LastPending) {
                $ResponseText = "J'ai préparé une action réelle ($($LastPending.connectorId) — $($LastPending.operation)). Elle n'est PAS encore envoyée — confirmez-la depuis votre tableau de bord pour qu'elle parte réellement."
            }
        }
    }

    # ---------------- CAPTURE DES FICHIERS GENERES (2026-10-08) --------
    # Les Workers peuvent produire un livrable (Excel/Word/PDF/CSV/image)
    # via code execution. Anthropic renvoie alors des blocs resultat
    # contenant un file_id ; on recupere les metadonnees puis les octets
    # via la Files API et on depose chaque fichier dans
    # runtime/task-files/<TaskId>/. Tout est encapsule dans un try/catch :
    # la moindre erreur laisse $CapturedFiles tel quel et la mission se
    # poursuit normalement (jamais de throw depuis ce bloc).
    $CapturedFiles = @()
    try {
        $FileIds = @($AllFileIds | Select-Object -Unique)
        $MaxFiles = 10; $MaxFileBytes = 25MB; $MaxTotalBytes = 60MB; $TotalBytes = 0
        $SkippedFiles = @()
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

            $DestDir = Join-Path (Join-Path $ProjectRoot "runtime/task-files") $TaskId
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
                path      = "$TaskId/$SafeName"
            }
        }
    }
    catch {
        # Jamais fatal : on conserve ce qui a ete capture jusqu'ici.
    }
    if ($SkippedFiles.Count -gt 0) {
        $ResponseText = ([string]$ResponseText).TrimEnd() + "`n`n(Attention : " + $SkippedFiles.Count + " fichier(s) non joint(s) car trop volumineux ou en trop grand nombre : " + (($SkippedFiles | Select-Object -First 5) -join ", ") + ".)"
    }

    $ExitCode = 0
}
catch {
    $ErrorDetail = $_.Exception.Message
    $ExitCode = 1
}
finally {
    $PlainKey = $null
}

if ($ExitCode -eq 0) {
    $ResultObj = [ordered]@{
        status="SUCCESS"; provider="anthropic"; model=$EffectiveModel; mode="LLM"; api_call=$true
        client_id=$ClientId; project_id=$ProjectId; worker=$WorkerId.ToUpper(); task_id=$TaskId
        answer=$ResponseText; recommendations=@()
        files=@($CapturedFiles)
        # usage = jetons CUMULES sur tous les appels de la mission + cout estime (USD/CHF), plafond et drapeau cost_capped
        # (Mission-Cost.ps1) : le resume des couts du dashboard lit estimated_cost_usd.
        usage=(Get-BKCostUsageFields -Cost $MissionCost)
        cost_capped=[bool]$MissionCost.Capped
        next_action="Utiliser la reponse du fournisseur dans le traitement du Worker."
        security_status="VALID"; financial_actions=$false; external_actions=$false
        generated_at=(Get-Date).ToUniversalTime().ToString("o")
    }
    if ($ConnectorActionsList.Count -gt 0) {
        $ResultObj["connector_action"] = $ConnectorActionsList[0]
        $ResultObj["connector_actions"] = $ConnectorActionsList
    }
    # Memoire de conversation v2 : ce tour est ajoute au fil (client, Worker) pour que le prochain message s'en souvienne.
    Add-BKConversationTurn -Root $ProjectRoot -ClientId $ClientId -WorkerId $WorkerId -TaskId $TaskId -Request $Objective -Answer $ResponseText -Files $CapturedFiles -Actions $ConnectorActionsList
    Write-Result $ResultObj
    exit 0
}
else {
    Write-Result ([ordered]@{ status="ERROR"; provider="anthropic"; model=$EffectiveModel; mode="LLM"; api_call=$true; answer=""; error=$ErrorDetail })
    exit 1
}
