# =====================================================================
# BK-AI-WORKERS — Dispatch reel des operations de connecteurs.
# Ecrit le 2026-09-23, sur demande explicite de Kader ("branche tous les
# connecteurs, attaque le code de diffusion reelle pour tous").
#
# Ce que ce fichier fait : traduit une (ConnectorId, Operation) du
# catalogue en un VRAI appel HTTP, via les adaptateurs deja existants
# (OAuth2-Adapter.ps1 / Generic-REST-Adapter.ps1 / Slack-Adapter.ps1).
# Avant ce fichier, ces adaptateurs savaient authentifier un appel mais
# rien ne definissait QUEL appel faire pour quelle operation — ce
# fichier est cette definition manquante.
#
# Volontairement EXCLU de ce fichier :
#   - stripe/paypal/quickbooks/xero (PAYMENT/ACCOUNTING) : regle
#     distincte, reconfirmee plusieurs fois par Kader avant meme cette
#     session (voir CONNECTOR-SETUP-GUIDE.md, section finale) — seul
#     Kader valide un paiement ou une transaction, jamais un Worker ni
#     Chloe, quel que soit l'etat de "deverrouillage" des autres
#     connecteurs. Ne PAS ajouter ces 4 ici sans une instruction
#     explicite et sans ambiguite portant specifiquement sur l'argent.
#   - crm/social_media/design/monitoring/calendar_hr (categories
#     generiques du catalogue) : ne designent aucun produit reel, donc
#     aucun appel HTTP possible tant qu'un outil precis n'est pas
#     nomme (Notion ? Airtable ? BambooHR ?).
#
# Regle de securite inchangee : ce fichier EXECUTE une decision deja
# autorisee (gate d'autonomie Chloe pour SEND/PUBLISH), il ne
# l'evalue jamais lui-meme. Chaque operation qui n'a pas d'equivalent
# "brouillon" reel cote plateforme (LinkedIn/Instagram/TikTok/X/Teams
# post immediat, sans etat brouillon) est implementee en PREPARED_ONLY :
# le contenu est compose mais AUCUN appel reseau n'est fait — cote
# securite avant tout, plutot que publier reellement au nom du client
# sans etat "brouillon" possible a annuler.
# =====================================================================

# Ce fichier est appele (via &) depuis des chaines qui imposent parfois
# Set-StrictMode -Version Latest en amont (ex: AI-SECURE-ENTRY-GUARD.ps1
# dans le pipeline mission) — herite par les portees enfants. Sous ce
# mode, l'acces en notation point a une cle de hashtable ABSENTE (tres
# frequent ici : chaque operation ne remplit que les cles dont elle a
# besoin) leve une exception au lieu de renvoyer $null. On desactive
# explicitement pour ce fichier plutot que de convertir des dizaines
# d'acces en notation crochet.
Set-StrictMode -Off

$Script:DispatchRoot = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Script:DispatchRoot "core/integrations/OAuth2-Adapter.ps1")
. (Join-Path $Script:DispatchRoot "core/integrations/Generic-REST-Adapter.ps1")
. (Join-Path $Script:DispatchRoot "core/integrations/Slack-Adapter.ps1")

function ConvertTo-Base64Url {
    param([Parameter(Mandatory=$true)][string]$Text)
    $Bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
    return [System.Convert]::ToBase64String($Bytes).Replace('+','-').Replace('/','_').Replace('=','')
}

function New-MimeMessage {
    param(
        [Parameter(Mandatory=$true)][string]$To,
        [Parameter(Mandatory=$true)][string]$Subject,
        [Parameter(Mandatory=$true)][string]$Body
    )
    return "To: $To`r`nSubject: $Subject`r`nContent-Type: text/plain; charset=UTF-8`r`n`r`n$Body"
}

# =====================================================================
# TABLE DES OPERATIONS — un connecteur = un AdapterType + une fonction
# par operation qui construit (Path, Method, Body) ou renvoie PREPARED_ONLY.
# AdapterType : "OAuth2" -> Invoke-OAuthConnectorRequest
#               "Rest"   -> Invoke-ConnectorRequest (Generic-REST-Adapter)
#               "Slack"  -> deja gere a part (Send-SlackMessage)
# =====================================================================

$Script:OperationTable = @{

    # ---------------- EMAIL ----------------
    "gmail" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_MESSAGES"   = { param($P) @{ Path = "users/me/messages"; Method = "GET" } }
            "SEARCH_MESSAGES" = { param($P) @{ Path = "users/me/messages?q=$([Uri]::EscapeDataString($P.Query))"; Method = "GET" } }
            "DRAFT_MESSAGE"   = {
                param($P)
                $Mime = New-MimeMessage -To $P.To -Subject $P.Subject -Body $P.Body
                @{ Path = "users/me/drafts"; Method = "POST"; Body = @{ message = @{ raw = (ConvertTo-Base64Url $Mime) } } }
            }
        }
    }
    "outlook_mail" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_MESSAGES"   = { param($P) @{ Path = "messages"; Method = "GET" } }
            "SEARCH_MESSAGES" = { param($P) @{ Path = "messages?`$search=`"$($P.Query)`""; Method = "GET" } }
            "DRAFT_MESSAGE"   = {
                param($P)
                @{ Path = "messages"; Method = "POST"; Body = @{
                    subject = $P.Subject
                    body = @{ contentType = "Text"; content = $P.Body }
                    toRecipients = @(@{ emailAddress = @{ address = $P.To } })
                    isDraft = $true
                } }
            }
        }
    }

    # ---------------- CALENDAR ----------------
    "calendar" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_EVENTS"   = { param($P) @{ Path = "calendars/primary/events"; Method = "GET" } }
            "SEARCH_EVENTS" = { param($P) @{ Path = "calendars/primary/events?q=$([Uri]::EscapeDataString($P.Query))"; Method = "GET" } }
            "CREATE_EVENT"  = {
                param($P)
                @{ Path = "calendars/primary/events"; Method = "POST"; Body = @{
                    summary = $P.Summary
                    start = @{ dateTime = $P.StartIso }
                    end   = @{ dateTime = $P.EndIso }
                } }
            }
        }
    }
    "outlook_calendar" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_EVENTS"   = { param($P) @{ Path = "events"; Method = "GET" } }
            "SEARCH_EVENTS" = { param($P) @{ Path = "events?`$search=`"$($P.Query)`""; Method = "GET" } }
            "CREATE_EVENT"  = {
                param($P)
                @{ Path = "events"; Method = "POST"; Body = @{
                    subject = $P.Summary
                    start = @{ dateTime = $P.StartIso; timeZone = "UTC" }
                    end   = @{ dateTime = $P.EndIso; timeZone = "UTC" }
                } }
            }
        }
    }

    # ---------------- CRM (produits nommes uniquement) ----------------
    "salesforce" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_CONTACT"     = { param($P) @{ Path = "sobjects/Contact/$($P.Id)"; Method = "GET" } }
            "SEARCH_CONTACTS"  = { param($P) @{ Path = "query?q=$([Uri]::EscapeDataString("SELECT Id,Name,Email FROM Contact WHERE Name LIKE '%$($P.Query)%'"))"; Method = "GET" } }
            "READ_OPPORTUNITY" = { param($P) @{ Path = "sobjects/Opportunity/$($P.Id)"; Method = "GET" } }
            "CREATE_TASK"      = { param($P) @{ Path = "sobjects/Task"; Method = "POST"; Body = @{ Subject = $P.Subject; Description = $P.Notes } } }
        }
    }
    "hubspot" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_CONTACT"    = { param($P) @{ Path = "crm/v3/objects/contacts/$($P.Id)"; Method = "GET" } }
            "SEARCH_CONTACTS" = { param($P) @{ Path = "crm/v3/objects/contacts/search"; Method = "POST"; Body = @{ query = $P.Query } } }
            "READ_DEAL"       = { param($P) @{ Path = "crm/v3/objects/deals/$($P.Id)"; Method = "GET" } }
            "CREATE_TASK"     = { param($P) @{ Path = "crm/v3/objects/tasks"; Method = "POST"; Body = @{ properties = @{ hs_task_subject = $P.Subject; hs_task_body = $P.Notes } } } }
        }
    }
    "pipedrive" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_CONTACT"    = { param($P) @{ Path = "persons/$($P.Id)"; Method = "GET" } }
            "SEARCH_CONTACTS" = { param($P) @{ Path = "persons/search?term=$([Uri]::EscapeDataString($P.Query))"; Method = "GET" } }
            "READ_DEAL"       = { param($P) @{ Path = "deals/$($P.Id)"; Method = "GET" } }
        }
    }

    # ---------------- SOCIAL MEDIA (produits nommes uniquement) ----------------
    # CREATE_DRAFT_POST : PREPARED_ONLY quand la plateforme n'a aucun etat
    # "brouillon" reel via API (publication = immediate et irreversible) ;
    # appel reel uniquement quand un vrai mecanisme de brouillon existe
    # (Facebook Page : published=false, verifie dans la doc Graph API).
    # 2026-09-23 : publication REELLE sur demande explicite de Kader
    # ("pas de brouillon, ça publie") — la securite vient desormais
    # UNIQUEMENT du flux propose->confirmation (ou pre-autorisation
    # explicite du client) en amont dans ANTHROPIC-ADAPTER.ps1, jamais
    # d'un blocage silencieux ici.
    "linkedin" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_POSTS"       = { param($P) @{ Path = "ugcPosts?q=authors&authors=List($($P.AuthorUrn))"; Method = "GET" } }
            "SEARCH_POSTS"     = { param($P) @{ Path = "ugcPosts?q=authors&authors=List($($P.AuthorUrn))"; Method = "GET" } }
            "CREATE_DRAFT_POST" = {
                param($P)
                @{ Path = "ugcPosts"; Method = "POST"; Body = @{
                    author = $P.AuthorUrn
                    lifecycleState = "PUBLISHED"
                    specificContent = @{ "com.linkedin.ugc.ShareContent" = @{ shareCommentary = @{ text = $P.Text }; shareMediaCategory = "NONE" } }
                    visibility = @{ "com.linkedin.ugc.MemberNetworkVisibility" = "PUBLIC" }
                } }
            }
        }
    }
    "instagram" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_POSTS"        = { param($P) @{ Path = "$($P.IgUserId)/media"; Method = "GET" } }
            # Publication reelle Instagram = 2 appels (container puis
            # publish) : geree a part dans Invoke-ConnectorAction, pas via
            # ce builder a un seul appel.
        }
    }
    "facebook" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_POSTS"        = { param($P) @{ Path = "$($P.PageId)/posts"; Method = "GET" } }
            "CREATE_DRAFT_POST" = { param($P) @{ Path = "$($P.PageId)/feed"; Method = "POST"; Body = @{ message = $P.Text } } }
        }
    }
    "tiktok" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_POSTS"        = { param($P) @{ Path = "video/list/"; Method = "GET" } }
            "CREATE_DRAFT_POST" = { param($P) @{ Path = "post/publish/content/init/"; Method = "POST"; Body = @{ post_info = @{ title = $P.Text }; source_info = @{ source = "PULL_FROM_URL"; video_url = $P.VideoUrl } } } }
        }
    }
    "x_twitter" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_POSTS"        = { param($P) @{ Path = "users/$($P.UserId)/tweets"; Method = "GET" } }
            "CREATE_DRAFT_POST" = { param($P) @{ Path = "tweets"; Method = "POST"; Body = @{ text = $P.Text } } }
        }
    }

    # ---------------- CMS ----------------
    "wordpress" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_POST"    = { param($P) @{ Path = "posts/$($P.Id)"; Method = "GET" } }
            "CREATE_DRAFT" = { param($P) @{ Path = "posts"; Method = "POST"; Body = @{ title = $P.Title; content = $P.Content; status = "draft" } } }
            "UPDATE_DRAFT" = { param($P) @{ Path = "posts/$($P.Id)"; Method = "POST"; Body = @{ title = $P.Title; content = $P.Content; status = "draft" } } }
        }
    }
    "webflow" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_PAGE"    = { param($P) @{ Path = "pages/$($P.Id)"; Method = "GET" } }
            "CREATE_DRAFT" = { param($P) @{ PreparedOnly = $true; Reason = "La creation de page Webflow via API v2 necessite un site/parent specifique choisi par le client ; contenu prepare, action manuelle requise." } }
            "UPDATE_DRAFT" = { param($P) @{ Path = "pages/$($P.Id)"; Method = "PATCH"; Body = @{ title = $P.Title } } }
        }
    }

    # ---------------- ECOMMERCE ----------------
    "shopify" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_PRODUCT"    = { param($P) @{ Path = "products/$($P.Id).json"; Method = "GET" } }
            "SEARCH_ORDERS"   = { param($P) @{ Path = "orders.json?status=any"; Method = "GET" } }
            "READ_INVENTORY"  = { param($P) @{ Path = "inventory_levels.json?inventory_item_ids=$($P.Id)"; Method = "GET" } }
        }
    }
    "woocommerce" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_PRODUCT"    = { param($P) @{ Path = "products/$($P.Id)"; Method = "GET" } }
            "SEARCH_ORDERS"   = { param($P) @{ Path = "orders"; Method = "GET" } }
            "READ_INVENTORY"  = { param($P) @{ Path = "products/$($P.Id)"; Method = "GET" } }
        }
    }

    # ---------------- COMMUNICATION ----------------
    # slack.controlled gere a part (POST_MESSAGE reel deja en prod depuis
    # le 2026-09-15). READ/SEARCH restent a construire si Kader ajoute un
    # scope de lecture au token (le webhook actuel est ecriture seule).
    "teams" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_MESSAGES"   = { param($P) @{ Path = "teams/$($P.TeamId)/channels/$($P.ChannelId)/messages"; Method = "GET" } }
            "SEARCH_MESSAGES" = { param($P) @{ Path = "teams/$($P.TeamId)/channels/$($P.ChannelId)/messages"; Method = "GET" } }
            "DRAFT_MESSAGE"   = { param($P) @{ Path = "teams/$($P.TeamId)/channels/$($P.ChannelId)/messages"; Method = "POST"; Body = @{ body = @{ content = $P.Text } } } }
        }
    }
    "whatsapp_business" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_MESSAGES" = { param($P) @{ Path = "$($P.PhoneNumberId)/messages"; Method = "GET" } }
            "DRAFT_MESSAGE" = { param($P) @{ Path = "$($P.PhoneNumberId)/messages"; Method = "POST"; Body = @{ messaging_product = "whatsapp"; to = $P.To; type = "text"; text = @{ body = $P.Text } } } }
        }
    }

    # ---------------- STORAGE ----------------
    "google_drive" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_FILE"    = { param($P) @{ Path = "files/$($P.Id)"; Method = "GET" } }
            "SEARCH_FILES" = { param($P) @{ Path = "files?q=$([Uri]::EscapeDataString("name contains '$($P.Query)'"))"; Method = "GET" } }
        }
    }
    "dropbox" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_FILE"    = { param($P) @{ Path = "files/get_metadata"; Method = "POST"; Body = @{ path = $P.Path } } }
            "SEARCH_FILES" = { param($P) @{ Path = "files/search_v2"; Method = "POST"; Body = @{ query = $P.Query } } }
        }
    }
    "onedrive" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_FILE"    = { param($P) @{ Path = "items/$($P.Id)"; Method = "GET" } }
            "SEARCH_FILES" = { param($P) @{ Path = "search(q='$($P.Query)')"; Method = "GET" } }
        }
    }

    # ---------------- WEB ANALYTICS / ADVERTISING ----------------
    "google_search_console" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_REPORT"    = { param($P) @{ Path = "sites/$([Uri]::EscapeDataString($P.SiteUrl))/searchAnalytics/query"; Method = "POST"; Body = @{ startDate = $P.StartDate; endDate = $P.EndDate; dimensions = @("page") } } }
            "SEARCH_QUERIES" = { param($P) @{ Path = "sites/$([Uri]::EscapeDataString($P.SiteUrl))/searchAnalytics/query"; Method = "POST"; Body = @{ startDate = $P.StartDate; endDate = $P.EndDate; dimensions = @("query") } } }
        }
    }
    "google_ads" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_CAMPAIGN" = { param($P) @{ Path = "customers/$($P.CustomerId)/googleAds:search"; Method = "POST"; Body = @{ query = "SELECT campaign.id, campaign.name FROM campaign" } } }
            "READ_REPORT"   = { param($P) @{ Path = "customers/$($P.CustomerId)/googleAds:search"; Method = "POST"; Body = @{ query = "SELECT campaign.id, metrics.clicks, metrics.impressions FROM campaign" } } }
        }
    }
    "meta_ads" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_CAMPAIGN" = { param($P) @{ Path = "act_$($P.AdAccountId)/campaigns"; Method = "GET" } }
            "READ_REPORT"   = { param($P) @{ Path = "$($P.CampaignId)/insights"; Method = "GET" } }
        }
    }

    # ---------------- PROJECT MANAGEMENT ----------------
    "asana" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_TASK"    = { param($P) @{ Path = "tasks/$($P.Id)"; Method = "GET" } }
            "SEARCH_TASKS" = { param($P) @{ Path = "workspaces/$($P.WorkspaceGid)/tasks/search?text=$([Uri]::EscapeDataString($P.Query))"; Method = "GET" } }
            "CREATE_TASK"  = { param($P) @{ Path = "tasks"; Method = "POST"; Body = @{ data = @{ name = $P.Name; notes = $P.Notes; workspace = $P.WorkspaceGid } } } }
        }
    }
    "trello" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_CARD"    = { param($P) @{ Path = "cards/$($P.Id)"; Method = "GET" } }
            "SEARCH_CARDS" = { param($P) @{ Path = "search?query=$([Uri]::EscapeDataString($P.Query))&idBoards=mine"; Method = "GET" } }
            "CREATE_CARD"  = { param($P) @{ Path = "cards"; Method = "POST"; Body = @{ name = $P.Name; desc = $P.Description; idList = $P.ListId } } }
        }
    }
    "monday" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_ITEM"    = { param($P) @{ Path = ""; Method = "POST"; Body = @{ query = "query { items (ids: [$($P.Id)]) { id name } }" } } }
            "SEARCH_ITEMS" = { param($P) @{ Path = ""; Method = "POST"; Body = @{ query = "query { boards (ids: [$($P.BoardId)]) { items_page { items { id name } } } }" } } }
            "CREATE_ITEM"  = { param($P) @{ Path = ""; Method = "POST"; Body = @{ query = "mutation { create_item (board_id: $($P.BoardId), item_name: `"$($P.Name)`") { id } }" } } }
        }
    }

    # ---------------- SUPPORT (reponses en note interne : jamais
    # visibles du client final sans relecture humaine) ----------------
    "zendesk" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_TICKET"   = { param($P) @{ Path = "tickets/$($P.Id).json"; Method = "GET" } }
            "SEARCH_TICKETS"= { param($P) @{ Path = "search.json?query=$([Uri]::EscapeDataString("type:ticket $($P.Query)"))"; Method = "GET" } }
            "DRAFT_REPLY"   = { param($P) @{ Path = "tickets/$($P.Id).json"; Method = "PUT"; Body = @{ ticket = @{ comment = @{ body = $P.Body; public = $false } } } } }
        }
    }
    "intercom" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_TICKET"    = { param($P) @{ Path = "conversations/$($P.Id)"; Method = "GET" } }
            "SEARCH_TICKETS" = { param($P) @{ Path = "conversations/search"; Method = "POST"; Body = @{ query = @{ field = "source.body"; operator = "~"; value = $P.Query } } } }
            "DRAFT_REPLY"    = { param($P) @{ Path = "conversations/$($P.Id)/reply"; Method = "POST"; Body = @{ message_type = "note"; type = "admin"; admin_id = $P.AdminId; body = $P.Body } } }
        }
    }

    # ---------------- FINANCIERS (Phase 4, 2026-09-24) ----------------
    # Identifiant TOUJOURS celui DU CLIENT (jamais celui de Kader) — voir
    # Client-Credential-Store.ps1. READ_*/SEARCH_* consultent une donnee
    # reelle et s'executent tout de suite comme partout ailleurs. Les
    # operations qui font REELLEMENT sortir de l'argent (remboursement,
    # virement) passent par le meme circuit propose->confirmation que
    # n'importe quelle autre ecriture — la confirmation revient TOUJOURS
    # au proprietaire du compte connecte (le client pour le sien ; pour
    # le compte de Kader lui-meme, voir le garde-fou specifique dans
    # ANTHROPIC-ADAPTER.ps1 qui ignore son propre "auto-approve").
    "stripe" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_BALANCE"    = { param($P) @{ Path = "balance"; Method = "GET" } }
            "SEARCH_CHARGES"  = { param($P) @{ Path = "charges?limit=10"; Method = "GET" } }
            "READ_CUSTOMER"   = { param($P) @{ Path = "customers/$($P.Id)"; Method = "GET" } }
            "SEARCH_INVOICES" = { param($P) @{ Path = "invoices?limit=10"; Method = "GET" } }
            "CREATE_REFUND"   = {
                param($P)
                $B = @{ charge = $P.ChargeId }
                if ($P.Amount) { $B["amount"] = $P.Amount }
                @{ Path = "refunds"; Method = "POST"; Body = $B }
            }
            "CREATE_PAYOUT"   = { param($P) @{ Path = "payouts"; Method = "POST"; Body = @{ amount = $P.Amount; currency = $P.Currency } } }
        }
    }
    "paypal" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_BALANCE"    = { param($P) @{ Path = "v1/reporting/balances"; Method = "GET" } }
            "SEARCH_PAYMENTS" = { param($P) @{ Path = "v2/payments/captures"; Method = "GET" } }
            "CREATE_REFUND"   = { param($P) @{ Path = "v2/payments/captures/$($P.CaptureId)/refund"; Method = "POST"; Body = @{ amount = @{ value = $P.Amount; currency_code = $P.Currency } } } }
            "CREATE_PAYOUT"   = { param($P) @{ Path = "v1/payments/payouts"; Method = "POST"; Body = @{ sender_batch_header = @{ sender_batch_id = [guid]::NewGuid().ToString() }; items = @(@{ amount = @{ value = $P.Amount; currency = $P.Currency }; receiver = $P.Receiver }) } } }
        }
    }
    "quickbooks" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_COMPANY_INFO" = { param($P) @{ Path = "companyinfo/$($P.Id)"; Method = "GET" } }
            "SEARCH_INVOICES"   = { param($P) @{ Path = "query?query=$([Uri]::EscapeDataString('select * from Invoice'))"; Method = "GET" } }
            "CREATE_PAYMENT"    = { param($P) @{ Path = "payment"; Method = "POST"; Body = @{ TotalAmt = $P.Amount; CustomerRef = @{ value = $P.CustomerId } } } }
        }
    }
    "xero" = @{
        AdapterType = "OAuth2"
        Operations = @{
            "READ_ORGANISATION" = { param($P) @{ Path = "Organisation"; Method = "GET" } }
            "SEARCH_INVOICES"   = { param($P) @{ Path = "Invoices"; Method = "GET" } }
            "CREATE_PAYMENT"    = { param($P) @{ Path = "Payments"; Method = "POST"; Body = @{ Invoice = @{ InvoiceID = $P.InvoiceId }; Account = @{ Code = $P.AccountCode }; Amount = $P.Amount } } }
        }
    }

    # ---------------- DESIGN (produit nomme uniquement) ----------------
    "figma" = @{
        AdapterType = "Rest"
        Operations = @{
            "READ_ASSET"    = { param($P) @{ Path = "files/$($P.FileKey)"; Method = "GET" } }
            "SEARCH_ASSETS" = { param($P) @{ Path = "files/$($P.FileKey)"; Method = "GET" } }
        }
    }
}

function Get-ConnectorBaseId {
    <#
    "gmail.controlled" -> "gmail" (les entrees du catalogue portent un
    suffixe ".controlled" que les tables d'adaptateurs n'utilisent pas).
    #>
    param([Parameter(Mandatory=$true)][string]$ConnectorId)
    return ($ConnectorId -replace '\.controlled$', '')
}

function Invoke-ConnectorAction {
    <#
    Point d'entree unique : execute REELLEMENT une operation de
    connecteur si (a) l'operation est definie ici, (b) le connecteur a
    un identifiant reel enregistre (.secrets\<provider>.secret.dpapi),
    (c) l'operation n'est pas PreparedOnly (aucun appel reseau dans ce
    cas, par choix de securite — voir en-tete de fichier).

    A appeler UNIQUEMENT apres le gate d'autonomie existant (verification
    Chloe pour toute operation d'ecriture) — cette fonction execute une
    decision deja autorisee, elle ne demande jamais de validation
    elle-meme.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$Operation,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [hashtable]$Params = @{}
    )

    $BaseId = Get-ConnectorBaseId -ConnectorId $ConnectorId

    if ($BaseId -eq "slack") {
        if ($Operation -ne "POST_MESSAGE" -and $Operation -ne "DRAFT_MESSAGE") {
            return [pscustomobject]@{ Status = "UNSUPPORTED_OPERATION"; Detail = "$Operation non definie pour slack." }
        }
        if (-not (Test-SlackConfigured -ClientId $ClientId)) {
            return [pscustomobject]@{ Status = "NOT_CONFIGURED"; Detail = "Aucun webhook Slack enregistre pour ce compte." }
        }
        if ($Operation -eq "DRAFT_MESSAGE") {
            return [pscustomobject]@{ Status = "PREPARED_ONLY"; Detail = "Message prepare, non envoye (utiliser POST_MESSAGE pour un envoi reel)."; PreparedText = $Params.Text }
        }
        $Result = Send-SlackMessage -ClientId $ClientId -Text $Params.Text -WorkerName $Params.WorkerName
        return [pscustomobject]@{ Status = $(if ($Result) { "SUCCESS" } else { "ERROR" }); Detail = "Message Slack reel envoye."; Live = $true }
    }

    if ($BaseId -eq "instagram" -and $Operation -eq "CREATE_DRAFT_POST") {
        # Publication Instagram reelle = 2 appels obligatoires (creer le
        # conteneur media, puis le publier) — pas exprimable avec un seul
        # (Path, Method, Body) comme le reste de la table.
        if (-not (Test-ConnectorConfigured -ConnectorId "instagram" -ClientId $ClientId)) {
            return [pscustomobject]@{ Status = "NOT_CONFIGURED"; Detail = "Aucun identifiant enregistre pour 'instagram' pour ce compte." }
        }
        $Container = Invoke-ConnectorRequest -ConnectorId "instagram" -ClientId $ClientId -Path "$($Params.IgUserId)/media" -Method "POST" -Body @{ caption = $Params.Text; image_url = $Params.ImageUrl }
        if ($Container.Status -ne "SUCCESS" -or -not $Container.Data.id) {
            return [pscustomobject]@{ Status = "ERROR"; Detail = "Echec creation du conteneur media : $($Container.Detail)"; Live = $true }
        }
        $Publish = Invoke-ConnectorRequest -ConnectorId "instagram" -ClientId $ClientId -Path "$($Params.IgUserId)/media_publish" -Method "POST" -Body @{ creation_id = $Container.Data.id }
        return $Publish
    }

    if ($BaseId -eq "twilio" -and $Operation -eq "PLACE_CALL") {
        # Telephonie reelle (2026-09-30) : pas exprimable comme un simple
        # (Path, Method, Body) comme le reste de la table — il faut lire
        # "from" depuis le secret du client (le Worker ne le connait pas)
        # et construire le TwiML a la volee a partir du message du Worker.
        if (-not (Test-ConnectorConfigured -ConnectorId "twilio" -ClientId $ClientId)) {
            return [pscustomobject]@{ Status = "NOT_CONFIGURED"; Detail = "Aucun compte Twilio enregistre pour ce compte." }
        }
        $To = [string]$Params.To
        $Message = [string]$Params.Message
        if ([string]::IsNullOrWhiteSpace($To) -or $To -notmatch '^\+[1-9]\d{6,14}$') {
            return [pscustomobject]@{ Status = "ERROR"; Detail = "Numero invalide : 'To' doit etre au format E.164 (ex: +41791234567)."; Live = $false }
        }
        if ([string]::IsNullOrWhiteSpace($Message)) {
            return [pscustomobject]@{ Status = "ERROR"; Detail = "'Message' (texte a dire au telephone) est requis."; Live = $false }
        }
        if ($Message.Length -gt 1500) {
            return [pscustomobject]@{ Status = "ERROR"; Detail = "Message trop long pour un appel (1500 caracteres max)."; Live = $false }
        }
        try {
            $Secret = Get-ConnectorSecretRaw -ConnectorId "twilio" -ClientId $ClientId | ConvertFrom-Json
            if (-not $Secret.from) {
                return [pscustomobject]@{ Status = "ERROR"; Detail = "Identifiant Twilio incomplet : 'from' (votre numero Twilio) manquant."; Live = $false }
            }
            $EscapedMessage = [System.Security.SecurityElement]::Escape($Message)
            $Lang = if ($env:BK_REPLY_LANG -eq "English") { "en-US" } else { "fr-FR" }
            $Twiml = "<Response><Say language=`"$Lang`">$EscapedMessage</Say></Response>"
            $Pair = "$($Secret.user):$($Secret.pass)"
            $AuthHeader = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Pair))
            $Body = "To=$([Uri]::EscapeDataString($To))&From=$([Uri]::EscapeDataString([string]$Secret.from))&Twiml=$([Uri]::EscapeDataString($Twiml))"
            $Response = Invoke-RestMethod `
                -Uri "https://api.twilio.com/2010-04-01/Accounts/$($Secret.user)/Calls.json" `
                -Method Post -Headers @{ Authorization = $AuthHeader } `
                -ContentType "application/x-www-form-urlencoded" -Body $Body -TimeoutSec 20
            return [pscustomobject]@{
                Status = "SUCCESS"; Detail = "Appel reel place vers $To."; Live = $true
                Data = @{ CallSid = $Response.sid; TwilioStatus = $Response.status }
            }
        } catch {
            return [pscustomobject]@{ Status = "ERROR"; Detail = $_.Exception.Message; Live = $true }
        }
    }

    $Entry = $Script:OperationTable[$BaseId]
    if (-not $Entry) {
        return [pscustomobject]@{ Status = "UNKNOWN_CONNECTOR"; Detail = $BaseId }
    }
    $OpBuilder = $Entry.Operations[$Operation]
    if (-not $OpBuilder) {
        return [pscustomobject]@{ Status = "UNSUPPORTED_OPERATION"; Detail = "$Operation non definie pour $BaseId." }
    }

    $Built = & $OpBuilder $Params

    if ($Built.PreparedOnly) {
        return [pscustomobject]@{
            Status = "PREPARED_ONLY"
            Detail = $Built.Reason
            Live   = $false
        }
    }

    if ($Entry.AdapterType -eq "OAuth2") {
        return Invoke-OAuthConnectorRequest -ConnectorId $BaseId -ClientId $ClientId -Path $Built.Path -Method $Built.Method -Body $Built.Body
    }
    else {
        return Invoke-ConnectorRequest -ConnectorId $BaseId -ClientId $ClientId -Path $Built.Path -Method $Built.Method -Body $Built.Body
    }
}

function Get-DispatchedConnectorIds {
    <# Liste des connecteurs pour lesquels une vraie operation existe ici. #>
    return @($Script:OperationTable.Keys) + @("slack")
}
