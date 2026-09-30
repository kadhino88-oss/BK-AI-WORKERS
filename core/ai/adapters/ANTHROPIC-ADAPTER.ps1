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

$PlainKey = $null
$ResponseText = $null; $ErrorDetail = $null; $ExitCode = 1
$Response = $null
$ConnectorActionTaken = $null

if (-not (Test-BKSecret -Name "anthropic")) {
    Write-Result ([ordered]@{ status="ERROR"; provider="anthropic"; model=$EffectiveModel; mode="SIMULATION"; api_call=$false; answer=""; error="CREDENTIAL_NOT_CONFIGURED" })
    exit 1
}

try {
    $PlainKey = Get-BKSecretValue -Name "anthropic"
    if ([string]::IsNullOrWhiteSpace($PlainKey)) { throw "CREDENTIAL_EMPTY" }

    $SystemPrompt = Get-WorkerSystemPrompt -WorkerId $WorkerId -ClientId $ClientId
    $ToolDef = Build-ConnectorToolDefinition -ClientId $ClientId
    $Messages = [System.Collections.ArrayList]@()
    foreach ($Turn in (Get-BKRecentConversationTurns -Root $ProjectRoot -ClientId $ClientId -WorkerId $WorkerId)) {
        [void]$Messages.Add($Turn)
    }
    [void]$Messages.Add(@{ role = "user"; content = $Objective })

    $BodyObj = [ordered]@{
        model      = $EffectiveModel
        max_tokens = 64000
        system     = $SystemPrompt
        messages   = $Messages
    }
    if ($ToolDef) { $BodyObj["tools"] = @($ToolDef) }

    $Headers = @{ "x-api-key" = $PlainKey; "anthropic-version" = "2023-06-01" }
    $Response = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
        -Headers $Headers -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes(($BodyObj | ConvertTo-Json -Depth 10))) -TimeoutSec 240

    # ---------------- OUTIL DEMANDE PAR CLAUDE ----------------
    if ($Response.stop_reason -eq "tool_use") {
        $ToolUse = $Response.content | Where-Object { $_.type -eq "tool_use" } | Select-Object -First 1

        if ($ToolUse) {
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
            if ((Test-ReadOnlyOperation -Operation $Op) -or $AutoApproved) {
                # Lecture : toujours executee reellement tout de suite
                # (aucun effet externe possible). Ecriture : executee
                # reellement tout de suite UNIQUEMENT si ce client a
                # explicitement pre-autorise ses Workers a agir sans
                # attendre (bascule "autoApprove", desactivee par defaut).
                # Dans les deux cas, on redonne la main a Claude avec le
                # resultat pour qu'il redige sa synthese finale.
                $ActionResult = Invoke-ConnectorAction -ConnectorId "$ConnId.controlled" -Operation $Op -ClientId $ClientId -Params $OpParams
                $ConnectorActionTaken = @{ connectorId = $ConnId; operation = $Op; status = $ActionResult.Status; executed = $true; autoApproved = $AutoApproved }

                $ToolResultContent = ($ActionResult | ConvertTo-Json -Depth 10 -Compress)
                [void]$Messages.Add(@{ role = "assistant"; content = $Response.content })
                [void]$Messages.Add(@{ role = "user"; content = @(@{ type = "tool_result"; tool_use_id = $ToolUse.id; content = $ToolResultContent }) })

                $BodyObj2 = [ordered]@{
                    model = $EffectiveModel; max_tokens = 64000; system = $SystemPrompt; messages = $Messages
                }
                if ($ToolDef) { $BodyObj2["tools"] = @($ToolDef) }
                $Response2 = Invoke-RestMethod -Uri "https://api.anthropic.com/v1/messages" -Method Post `
                    -Headers $Headers -ContentType "application/json; charset=utf-8" `
                    -Body ([System.Text.Encoding]::UTF8.GetBytes(($BodyObj2 | ConvertTo-Json -Depth 10))) -TimeoutSec 240

                $ResponseText = (@($Response2.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n")
                $Response = $Response2
            }
            else {
                # Ecriture : JAMAIS executee ici. On ecrit l'action proposee
                # sur disque pour confirmation explicite du client, et on
                # redige une reponse qui l'explique clairement.
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

                $ConnectorActionTaken = @{ connectorId = $ConnId; operation = $Op; status = "PENDING_CONFIRMATION"; executed = $false }
                $ResponseText = (@($Response.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n").Trim()
                if ([string]::IsNullOrWhiteSpace($ResponseText)) {
                    $ResponseText = "J'ai preparé une action réelle ($ConnId — $Op) : $Reason. Elle n'est PAS encore envoyée — confirmez-la depuis votre tableau de bord pour qu'elle parte réellement."
                } else {
                    $ResponseText += "`n`n(Action réelle préparée sur $ConnId — en attente de votre confirmation avant tout envoi effectif.)"
                }
            }
        }
    }
    else {
        $ResponseText = (@($Response.content | Where-Object { $_.type -eq "text" } | ForEach-Object { $_.text }) -join "`n")
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
        usage=[ordered]@{ input_tokens=[int]$Response.usage.input_tokens; output_tokens=[int]$Response.usage.output_tokens }
        next_action="Utiliser la reponse du fournisseur dans le traitement du Worker."
        security_status="VALID"; financial_actions=$false; external_actions=$false
        generated_at=(Get-Date).ToUniversalTime().ToString("o")
    }
    if ($ConnectorActionTaken) { $ResultObj["connector_action"] = $ConnectorActionTaken }
    Write-Result $ResultObj
    exit 0
}
else {
    Write-Result ([ordered]@{ status="ERROR"; provider="anthropic"; model=$EffectiveModel; mode="LLM"; api_call=$true; answer=""; error=$ErrorDetail })
    exit 1
}
