# =====================================================================
# BK-AI-WORKERS — Adaptateur REST generique (connecteurs a jeton/cle API
# simple : pas d'OAuth, un seul secret DPAPI suffit). Couvre Trello,
# Asana, Monday, Zendesk, Intercom, Figma, HubSpot, Pipedrive, Webflow,
# Shopify, WooCommerce, WordPress, Dropbox.
#
# Meme philosophie que Slack-Adapter.ps1 : si le secret DPAPI n'existe
# pas, la fonction renvoie NOT_CONFIGURED sans tenter le moindre appel.
# Le secret est stocke par Kader lui-meme via .secrets\Store-Credential.ps1
# (jamais vu par Claude). Pour les connecteurs necessitant plusieurs
# valeurs (ex: Zendesk = sous-domaine + email + token ; Shopify = nom de
# boutique + token), le secret stocke est un petit JSON serialise
# (ConvertTo-Json) colle tel quel dans Store-Credential.ps1 — voir
# CONNECTOR-SETUP-GUIDE.md pour le format exact attendu par connecteur.
#
# Ecrit le 2026-09-15.
# =====================================================================

. (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/connectors/Client-Credential-Store.ps1")

# Table de config : un connecteur = un schema d'authentification + une
# URL de base. "authType" determine comment le secret dechiffre est
# applique a la requete :
#   Bearer       -> Authorization: Bearer <secret>
#   HeaderRaw    -> <authHeader>: <secret>  (pas de prefixe "Bearer")
#   BasicUserPwd -> secret JSON {user, pass} -> Authorization: Basic base64(user:pass)
#   QueryParam   -> secret ajoute en ?<queryParamName>=<secret>
#   QueryJson    -> secret JSON {..} -> chaque cle ajoutee en query string
$Script:ConnectorConfig = @{
    "trello"      = @{ Provider = "trello";      AuthType = "QueryJson";     BaseUrl = "https://api.trello.com/1" }
    "asana"       = @{ Provider = "asana";       AuthType = "Bearer";       BaseUrl = "https://app.asana.com/api/1.0" }
    "monday"      = @{ Provider = "monday";      AuthType = "HeaderRaw";    AuthHeader = "Authorization"; BaseUrl = "https://api.monday.com/v2" }
    "zendesk"     = @{ Provider = "zendesk";     AuthType = "BasicUserPwd"; BaseUrlTemplate = "https://{subdomain}.zendesk.com/api/v2" }
    "intercom"    = @{ Provider = "intercom";    AuthType = "Bearer";       BaseUrl = "https://api.intercom.io" }
    "figma"       = @{ Provider = "figma";       AuthType = "HeaderRaw";    AuthHeader = "X-Figma-Token"; BaseUrl = "https://api.figma.com/v1" }
    "hubspot"     = @{ Provider = "hubspot";     AuthType = "Bearer";       BaseUrl = "https://api.hubapi.com" }
    "pipedrive"   = @{ Provider = "pipedrive";   AuthType = "QueryParam";   QueryParamName = "api_token"; BaseUrl = "https://api.pipedrive.com/v1" }
    "webflow"     = @{ Provider = "webflow";     AuthType = "Bearer";       BaseUrl = "https://api.webflow.com/v2" }
    "shopify"     = @{ Provider = "shopify";     AuthType = "HeaderRawJson"; AuthHeader = "X-Shopify-Access-Token"; BaseUrlTemplate = "https://{shop}.myshopify.com/admin/api/2024-01" }
    "woocommerce" = @{ Provider = "woocommerce"; AuthType = "QueryJson";    BaseUrlTemplate = "https://{site}/wp-json/wc/v3" }
    "wordpress"   = @{ Provider = "wordpress";   AuthType = "BasicUserPwd"; BaseUrlTemplate = "https://{site}/wp-json/wp/v2" }
    "dropbox"     = @{ Provider = "dropbox";     AuthType = "Bearer";       BaseUrl = "https://api.dropboxapi.com/2" }

    # Reseaux sociaux / publicite : jeton longue duree (System User /
    # Page token) obtenu manuellement dans l'outil business de la
    # plateforme plutot qu'un flux refresh_token classique — c'est la
    # pratique standard pour un usage "compte d'entreprise", pas un
    # detournement. A renouveler par Kader quand la plateforme l'exige
    # (variable selon le fournisseur, voir CONNECTOR-SETUP-GUIDE.md).
    "linkedin"          = @{ Provider = "linkedin";          AuthType = "Bearer"; BaseUrl = "https://api.linkedin.com/v2" }
    "facebook"          = @{ Provider = "facebook";          AuthType = "Bearer"; BaseUrl = "https://graph.facebook.com/v19.0" }
    "instagram"         = @{ Provider = "instagram";         AuthType = "Bearer"; BaseUrl = "https://graph.facebook.com/v19.0" }
    "tiktok"             = @{ Provider = "tiktok";             AuthType = "Bearer"; BaseUrl = "https://open.tiktokapis.com/v2" }
    "x_twitter"          = @{ Provider = "x_twitter";          AuthType = "Bearer"; BaseUrl = "https://api.twitter.com/2" }
    "meta_ads"            = @{ Provider = "meta_ads";           AuthType = "Bearer"; BaseUrl = "https://graph.facebook.com/v19.0" }
    "whatsapp_business"   = @{ Provider = "whatsapp_business";  AuthType = "Bearer"; BaseUrl = "https://graph.facebook.com/v19.0" }

    # Stripe : cle secrete (sk_...) DU CLIENT LUI-MEME, jamais celle de
    # Kader (utilisee ailleurs, separement, pour la facturation de la
    # plateforme — voir Stripe-Bridge.ps1). Phase 4 (2026-09-24).
    "stripe" = @{ Provider = "stripe"; AuthType = "Bearer"; BaseUrl = "https://api.stripe.com/v1"; BodyEncoding = "Form" }
}

function Test-ConnectorConfigured {
    <#
    2026-09-24 : identifiant PAR CLIENT (Client-Credential-Store.ps1) —
    chaque client connecte son propre compte, plus d'identifiant partage
    entre tous les clients de la plateforme.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId
    )
    $Cfg = $Script:ConnectorConfig[$ConnectorId]
    if (-not $Cfg) { return $false }
    return Test-BKClientCredential -ClientId $ClientId -Provider $Cfg.Provider
}

function Get-ConnectorSecretRaw {
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId
    )
    $Cfg = $Script:ConnectorConfig[$ConnectorId]
    if (-not $Cfg) { throw "UNKNOWN_CONNECTOR:$ConnectorId" }
    if (-not (Test-BKClientCredential -ClientId $ClientId -Provider $Cfg.Provider)) {
        throw "CONNECTOR_NOT_CONFIGURED:$ConnectorId"
    }
    return Get-BKClientCredentialValue -ClientId $ClientId -Provider $Cfg.Provider
}

function Resolve-OAuthBearer {
    <#
    Jeton obtenu par "Se connecter avec ..." : le secret stocke est un JSON
    {access_token, refresh_token?, expires_at?, vendor}. Renvoie le jeton
    d'acces a utiliser ; s'il est expire (ou sur le point de l'etre) et
    qu'un refresh_token existe, le renouvelle aupres du fournisseur avec
    l'application OAuth du serveur (variables OAUTH_<FOURNISSEUR>_...) et
    sauvegarde le nouveau jeton chiffre. Un secret qui n'est pas de ce
    format (jeton brut du proprietaire) est renvoye tel quel.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Provider,
        [Parameter(Mandatory=$true)][string]$Secret
    )
    if (-not $Secret.TrimStart().StartsWith("{")) { return $Secret }
    try { $Obj = $Secret | ConvertFrom-Json } catch { return $Secret }
    if (-not $Obj.access_token) { return $Secret }

    $Now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $Expired = $Obj.expires_at -and ([int64]$Obj.expires_at - 60) -le $Now
    if (-not $Expired -or -not $Obj.refresh_token) { return [string]$Obj.access_token }

    $VendorName = if ($Obj.vendor) { [string]$Obj.vendor } else { $Provider }
    $VendorFile = Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/integrations/oauth-vendors.json"
    $Def = (Get-Content -LiteralPath $VendorFile -Raw -Encoding UTF8 | ConvertFrom-Json).$VendorName
    $AppId = [Environment]::GetEnvironmentVariable("OAUTH_" + $VendorName.ToUpper() + "_CLIENT_ID")
    $AppSecret = [Environment]::GetEnvironmentVariable("OAUTH_" + $VendorName.ToUpper() + "_CLIENT_SECRET")
    if (-not $Def -or -not $AppId -or -not $AppSecret) { throw "OAUTH_APP_NOT_CONFIGURED:$VendorName" }

    $New = Invoke-RestMethod -Uri $Def.tokenUrl -Method Post -TimeoutSec 30 -Body @{
        grant_type = "refresh_token"; refresh_token = [string]$Obj.refresh_token
        client_id = $AppId; client_secret = $AppSecret
    }
    if (-not $New.access_token) { throw "OAUTH_REFRESH_FAILED:$VendorName" }
    $Updated = @{ access_token = [string]$New.access_token; vendor = $VendorName }
    $Updated.refresh_token = if ($New.refresh_token) { [string]$New.refresh_token } else { [string]$Obj.refresh_token }
    if ($New.expires_in) { $Updated.expires_at = [int64]($Now + [int64]$New.expires_in) }
    Set-BKClientCredentialValue -ClientId $ClientId -Provider $Provider -PlainText ($Updated | ConvertTo-Json -Compress)
    return [string]$New.access_token
}

function Invoke-ConnectorRequest {
    <#
    Appel REST reel generique vers un connecteur "a jeton simple".
    A n'appeler qu'APRES le gate d'autonomie existant (verification
    Chloe pour toute action SEND/PUBLISH/CREATE a risque) — cette
    fonction execute une decision deja autorisee, elle ne l'evalue pas.

    -Path : chemin relatif SANS le slash de tete (ex: "cards" pour Trello).
    -Method : GET/POST/PUT/DELETE (defaut GET).
    -Body : hashtable optionnel, serialise en JSON pour les methodes non-GET.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ConnectorId,
        [Parameter(Mandatory=$true)][string]$ClientId,
        [string]$Path = "",
        [string]$Method = "GET",
        [hashtable]$Body = $null
    )

    $Cfg = $Script:ConnectorConfig[$ConnectorId]
    if (-not $Cfg) {
        return [pscustomobject]@{ Status = "UNKNOWN_CONNECTOR"; Detail = $ConnectorId }
    }

    if (-not (Test-ConnectorConfigured -ConnectorId $ConnectorId -ClientId $ClientId)) {
        return [pscustomobject]@{
            Status = "NOT_CONFIGURED"
            Detail = "Aucun identifiant '$($Cfg.Provider)' enregistre pour ce compte."
        }
    }

    try {
        $Secret = Get-ConnectorSecretRaw -ConnectorId $ConnectorId -ClientId $ClientId
        if ($Cfg.AuthType -in @("Bearer", "HeaderRaw", "QueryParam")) {
            $Secret = Resolve-OAuthBearer -ClientId $ClientId -Provider $Cfg.Provider -Secret $Secret
        }
        $Headers = @{ Accept = "application/json" }
        $BaseUrl = $Cfg.BaseUrl
        $QueryExtra = @{}

        switch ($Cfg.AuthType) {
            "Bearer"        { $Headers["Authorization"] = "Bearer $Secret" }
            "HeaderRaw"     { $Headers[$Cfg.AuthHeader] = $Secret }
            "HeaderRawJson" {
                $Parsed = $Secret | ConvertFrom-Json
                $Headers[$Cfg.AuthHeader] = $Parsed.token
                $BaseUrl = $Cfg.BaseUrlTemplate -replace '\{shop\}', $Parsed.shop
            }
            "BasicUserPwd"  {
                $Parsed = $Secret | ConvertFrom-Json
                if ($Parsed.bearer_token) {
                    # Variante OAuth (ex: Zendesk OAuth Client) plutot que
                    # jeton API classique + email : le JSON contient
                    # "bearer_token" au lieu de "user"/"pass".
                    $Headers["Authorization"] = "Bearer $($Parsed.bearer_token)"
                } else {
                    $Pair = "$($Parsed.user):$($Parsed.pass)"
                    $Headers["Authorization"] = "Basic " + [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Pair))
                }
                if ($Cfg.BaseUrlTemplate) {
                    $BaseUrl = $Cfg.BaseUrlTemplate -replace '\{subdomain\}', $Parsed.subdomain -replace '\{site\}', $Parsed.site
                }
            }
            "QueryParam"    { $QueryExtra[$Cfg.QueryParamName] = $Secret }
            "QueryJson"     {
                $Parsed = $Secret | ConvertFrom-Json
                $Parsed.PSObject.Properties | ForEach-Object {
                    if ($_.Name -ne "site") { $QueryExtra[$_.Name] = $_.Value }
                }
                if ($Cfg.BaseUrlTemplate -and $Parsed.site) {
                    $BaseUrl = $Cfg.BaseUrlTemplate -replace '\{site\}', $Parsed.site
                }
            }
        }

        $QueryString = ($QueryExtra.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))" }) -join "&"
        $Separator = if ($Path -match '\?') { "&" } else { "?" }
        $PathSuffix = if ($Path) { "/$Path" } else { "" }
        $Uri = "$BaseUrl$PathSuffix" + $(if ($QueryString) { "$Separator$QueryString" } else { "" })

        $Params = @{
            Uri         = $Uri
            Method      = $Method
            Headers     = $Headers
            TimeoutSec  = 20
        }
        if ($Body -and $Method -ne "GET") {
            if ($Cfg.BodyEncoding -eq "Form") {
                # Stripe attend du x-www-form-urlencoded, pas du JSON, sur
                # son API REST classique (params plats uniquement — suffisant
                # pour les operations definies ici).
                $Params["ContentType"] = "application/x-www-form-urlencoded"
                $Params["Body"] = ($Body.GetEnumerator() | ForEach-Object { "$($_.Key)=$([Uri]::EscapeDataString([string]$_.Value))" }) -join "&"
            } else {
                $Params["ContentType"] = "application/json; charset=utf-8"
                $Params["Body"] = ($Body | ConvertTo-Json -Depth 10)
            }
        }

        $Response = Invoke-RestMethod @Params

        return [pscustomobject]@{
            Status = "SUCCESS"
            Detail = "Appel reel effectue."
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

function Get-AllConnectorIds {
    return $Script:ConnectorConfig.Keys
}
