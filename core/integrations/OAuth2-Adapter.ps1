# =====================================================================
# BK-AI-WORKERS — Adaptateur OAuth2 generique (refresh_token grant).
# Couvre les connecteurs Google (Gmail, Calendar, Drive, Search Console,
# Ads) et Microsoft (Outlook Mail/Calendar, Teams) et Salesforce — tous
# utilisent le meme mecanisme standard OAuth2 "refresh_token" pour
# obtenir un access_token de courte duree a chaque appel.
#
# Le secret DPAPI stocke pour ces connecteurs est un JSON avec :
#   { "client_id": "...", "client_secret": "...", "refresh_token": "...",
#     "tenant": "..." (Microsoft uniquement), "instance_url": "..." (Salesforce),
#     "developer_token": "..." (Google Ads uniquement) }
# Voir CONNECTOR-SETUP-GUIDE.md pour la procedure d'obtention par
# plateforme (creation de l'app OAuth, consentement, etc. — a faire par
# Kader lui-meme, jamais par Claude).
#
# Ecrit le 2026-09-15.
# =====================================================================

. (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/connectors/Client-Credential-Store.ps1")

$Script:OAuthConnectorConfig = @{
    "gmail"                  = @{ Provider = "gmail";                  TokenEndpoint = "https://oauth2.googleapis.com/token";           BaseUrl = "https://gmail.googleapis.com/gmail/v1" }
    "calendar"                = @{ Provider = "google_calendar";        TokenEndpoint = "https://oauth2.googleapis.com/token";           BaseUrl = "https://www.googleapis.com/calendar/v3" }
    "google_drive"            = @{ Provider = "google_drive";           TokenEndpoint = "https://oauth2.googleapis.com/token";           BaseUrl = "https://www.googleapis.com/drive/v3" }
    "google_search_console"   = @{ Provider = "google_search_console";  TokenEndpoint = "https://oauth2.googleapis.com/token";           BaseUrl = "https://www.googleapis.com/webmasters/v3" }
    "google_ads"               = @{ Provider = "google_ads";             TokenEndpoint = "https://oauth2.googleapis.com/token";           BaseUrl = "https://googleads.googleapis.com/v17"; NeedsDeveloperToken = $true }
    "outlook_mail"             = @{ Provider = "outlook_mail";           TokenEndpointTemplate = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"; BaseUrl = "https://graph.microsoft.com/v1.0/me" }
    "outlook_calendar"         = @{ Provider = "outlook_calendar";       TokenEndpointTemplate = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"; BaseUrl = "https://graph.microsoft.com/v1.0/me" }
    "teams"                    = @{ Provider = "teams";                  TokenEndpointTemplate = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"; BaseUrl = "https://graph.microsoft.com/v1.0" }
    "onedrive"                 = @{ Provider = "onedrive";               TokenEndpointTemplate = "https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"; BaseUrl = "https://graph.microsoft.com/v1.0/me/drive" }
    "salesforce"                = @{ Provider = "salesforce";             TokenEndpoint = "https://login.salesforce.com/services/oauth2/token"; BaseUrlFromToken = $true }

    # ---------------- FINANCIERS (2026-09-24, Phase 4) ----------------
    # PayPal : grant_type "client_credentials" (pas de refresh_token, pas
    # de consentement navigateur — cle+secret suffisent, jeton renouvele
    # a chaque appel). QuickBooks/Xero : OAuth2 classique comme Google/
    # Microsoft, avec un identifiant d'entreprise (realm/tenant) dans
    # l'URL de base, comme Salesforce utilise instance_url.
    "paypal"     = @{ Provider = "paypal";     GrantType = "client_credentials"; TokenEndpoint = "https://api-m.paypal.com/v1/oauth2/token"; BaseUrl = "https://api-m.paypal.com" }
    "quickbooks" = @{ Provider = "quickbooks"; TokenEndpoint = "https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer"; BaseUrlTemplate = "https://quickbooks.api.intuit.com/v3/company/{realm}" }
    "xero"       = @{ Provider = "xero";       TokenEndpoint = "https://identity.xero.com/connect/token"; BaseUrlTemplate = "https://api.xero.com/api.xro/2.0" }
}

function Test-OAuthConnectorConfigured {
    <#
    2026-09-24 : identifiant PAR CLIENT (Client-Credential-Store.ps1) —
    chaque client connecte son propre compte Google/Microsoft/Salesforce,
    plus d'identifiant unique partage entre tous les clients.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId
    )
    $Cfg = $Script:OAuthConnectorConfig[$ConnectorId]
    if (-not $Cfg) { throw "UNKNOWN_OAUTH_CONNECTOR:$ConnectorId" }
    return Test-BKClientCredential -ClientId $ClientId -Provider $Cfg.Provider
}

function Get-OAuthSecretJson {
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId
    )
    $Cfg = $Script:OAuthConnectorConfig[$ConnectorId]
    if (-not $Cfg) { throw "UNKNOWN_OAUTH_CONNECTOR:$ConnectorId" }
    if (-not (Test-BKClientCredential -ClientId $ClientId -Provider $Cfg.Provider)) {
        throw "OAUTH_CONNECTOR_NOT_CONFIGURED:$ConnectorId"
    }
    $Raw = Get-BKClientCredentialValue -ClientId $ClientId -Provider $Cfg.Provider
    return $Raw | ConvertFrom-Json
}

function Get-OAuthAccessToken {
    <#
    Echange le refresh_token stocke (celui DE CE CLIENT) contre un
    access_token de courte duree (appel reseau reel a chaque invocation
    — ces tokens expirent en 30-60 min chez Google/Microsoft, pas de
    cache necessaire pour un usage Worker ponctuel).
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId
    )

    $Cfg = $Script:OAuthConnectorConfig[$ConnectorId]
    $Secret = Get-OAuthSecretJson -ConnectorId $ConnectorId -ClientId $ClientId

    $TokenEndpoint = if ($Cfg.TokenEndpointTemplate) {
        $Cfg.TokenEndpointTemplate -replace '\{tenant\}', $Secret.tenant
    } else {
        $Cfg.TokenEndpoint
    }

    if ($Cfg.GrantType -eq "client_credentials") {
        # PayPal : cle+secret en Basic Auth, pas de refresh_token — un
        # jeton de courte duree est redemande a chaque appel, comme pour
        # le flux refresh_token des autres connecteurs.
        $BasicPair = "$($Secret.client_id):$($Secret.client_secret)"
        $BasicAuth = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($BasicPair))
        $Response = Invoke-RestMethod -Uri $TokenEndpoint -Method Post `
            -Headers @{ Authorization = "Basic $BasicAuth" } `
            -Body @{ grant_type = "client_credentials" } -TimeoutSec 20
        return [pscustomobject]@{
            AccessToken    = $Response.access_token
            InstanceUrl    = $null
            DeveloperToken = $null
            RealmOrTenant  = $null
        }
    }

    $Body = @{
        client_id     = $Secret.client_id
        client_secret = $Secret.client_secret
        refresh_token = $Secret.refresh_token
        grant_type    = "refresh_token"
    }

    $Response = Invoke-RestMethod -Uri $TokenEndpoint -Method Post -Body $Body -TimeoutSec 20
    return [pscustomobject]@{
        AccessToken    = $Response.access_token
        InstanceUrl    = if ($Response.instance_url) { $Response.instance_url } else { $null }
        RealmOrTenant  = if ($Secret.realm) { $Secret.realm } elseif ($Secret.tenant_id) { $Secret.tenant_id } else { $null }
        DeveloperToken = $Secret.developer_token
    }
}

function Invoke-OAuthConnectorRequest {
    <#
    Appel REST reel vers un connecteur OAuth2. A n'appeler qu'APRES le
    gate d'autonomie existant (verification Chloe pour SEND/PUBLISH/
    CREATE a risque) — execute une decision deja autorisee.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$Path = "",
        [string]$Method = "GET",
        [hashtable]$Body = $null
    )

    $Cfg = $Script:OAuthConnectorConfig[$ConnectorId]
    if (-not $Cfg) {
        return [pscustomobject]@{ Status = "UNKNOWN_CONNECTOR"; Detail = $ConnectorId }
    }

    if (-not (Test-OAuthConnectorConfigured -ConnectorId $ConnectorId -ClientId $ClientId)) {
        return [pscustomobject]@{
            Status = "NOT_CONFIGURED"
            Detail = "Aucun identifiant OAuth '$ConnectorId' enregistre pour ce compte."
        }
    }

    try {
        $Token = Get-OAuthAccessToken -ConnectorId $ConnectorId -ClientId $ClientId
        $Headers = @{ Authorization = "Bearer $($Token.AccessToken)" }
        if ($Cfg.NeedsDeveloperToken -and $Token.DeveloperToken) {
            $Headers["developer-token"] = $Token.DeveloperToken
        }
        if ($ConnectorId -eq "xero" -and $Token.RealmOrTenant) {
            # Xero identifie l'organisation via un en-tete dedie, pas dans
            # l'URL (contrairement a QuickBooks qui utilise {realm}).
            $Headers["Xero-tenant-id"] = $Token.RealmOrTenant
        }

        $BaseUrl = if ($Cfg.BaseUrlFromToken -and $Token.InstanceUrl) { "$($Token.InstanceUrl)/services/data/v59.0" }
                   elseif ($Cfg.BaseUrlTemplate) { $Cfg.BaseUrlTemplate -replace '\{realm\}', $Token.RealmOrTenant }
                   else { $Cfg.BaseUrl }
        $PathSuffix = if ($Path) { "/$Path" } else { "" }

        $Params = @{
            Uri        = "$BaseUrl$PathSuffix"
            Method     = $Method
            Headers    = $Headers
            TimeoutSec = 20
        }
        if ($Body -and $Method -ne "GET") {
            $Params["ContentType"] = "application/json; charset=utf-8"
            $Params["Body"] = ($Body | ConvertTo-Json -Depth 10)
        }

        $Response = Invoke-RestMethod @Params

        return [pscustomobject]@{
            Status = "SUCCESS"
            Detail = "Appel OAuth reel effectue."
            Live   = $true
            Data   = $Response
        }
    }
    catch {
        return [pscustomobject]@{
            Status = "ERROR"
            Detail = $_.Exception.Message
            Live   = $true
        }
    }
}
