# =====================================================================
# BK-AI-WORKERS — Pont OAuth Google ("Se connecter avec Google").
# Appele par dashboard/server.py (/oauth/google/start et /callback).
# Parametres par -InFile (JSON), resultat dans -OutFile — jamais de
# valeur interpolee dans une commande.
#
# L'application OAuth Google est CELLE DE KADER (client_id/client_secret
# deja stockes chiffres dans son espace CLI-DASHBOARD, provider "gmail",
# par Connect-GoogleWorkspace.ps1). Le secret d'application ne quitte
# jamais ce processus : ni renvoye au navigateur, ni journalise, ni vu
# par Claude. Le client final, lui, ne voit et ne colle AUCUN jeton : il
# se connecte avec son propre compte Google sur l'ecran de consentement
# de Google ; seul le refresh_token de SON compte est ensuite stocke,
# chiffre, dans SON espace.
#
#   action "app"      -> { ok, clientId }   (identifiant public d'application)
#   action "exchange" -> echange code -> refresh_token, stocke pour chaque
#                        provider demande, renvoie { ok, email, providers }
# =====================================================================

param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/connectors/Client-Credential-Store.ps1")

$OwnerClientId = "CLI-DASHBOARD"
$Request = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json

# Fournisseurs "Se connecter avec ..." : l'application OAuth de chacun est celle
# de Kader, dont client_id/client_secret sont deja dans son coffre (CLI-DASHBOARD).
$Vendors = @{
    google = @{
        tokenUrl  = "https://oauth2.googleapis.com/token"
        userInfo  = "https://openidconnect.googleapis.com/v1/userinfo"
        providers = @("gmail", "google_calendar", "google_drive", "google_search_console")
        tenant    = $null
    }
    microsoft = @{
        tokenUrl  = "https://login.microsoftonline.com/common/oauth2/v2.0/token"
        userInfo  = "https://graph.microsoft.com/oidc/userinfo"
        providers = @("outlook_mail", "outlook_calendar", "teams", "onedrive")
        tenant    = "common"
    }
}
# Autres fournisseurs : definition partagee avec le serveur (oauth-vendors.json)
$VendorFile = Join-Path $Root "core/integrations/oauth-vendors.json"
if (Test-Path -LiteralPath $VendorFile) {
    $Json = Get-Content -LiteralPath $VendorFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($P in $Json.PSObject.Properties) {
        if ($P.Name.StartsWith("_") -or $Vendors.ContainsKey($P.Name)) { continue }
        $Vendors[$P.Name] = @{
            tokenUrl  = $P.Value.tokenUrl
            userInfo  = $null
            providers = @($P.Value.providers.PSObject.Properties.Name)
            tenant    = $null
            env       = $true
            store     = $P.Value.store
            authStyle = $P.Value.authStyle
        }
    }
}
$VendorName = if ($Request.vendor) { [string]$Request.vendor } else { "google" }
$Vendor = $Vendors[$VendorName]

function Get-VendorApp {
    if (-not $Vendor) { throw "UNKNOWN_VENDOR" }
    if ($Vendor.env) {
        $Id = [Environment]::GetEnvironmentVariable("OAUTH_" + $VendorName.ToUpper() + "_CLIENT_ID")
        $Secret = [Environment]::GetEnvironmentVariable("OAUTH_" + $VendorName.ToUpper() + "_CLIENT_SECRET")
        if (-not $Id -or -not $Secret) { throw ($VendorName.ToUpper() + "_APP_NOT_CONFIGURED") }
        return [pscustomobject]@{ client_id = $Id; client_secret = $Secret }
    }
    foreach ($P in $Vendor.providers) {
        if (Test-BKClientCredential -ClientId $OwnerClientId -Provider $P) {
            $J = (Get-BKClientCredentialValue -ClientId $OwnerClientId -Provider $P) | ConvertFrom-Json
            if ($J.client_id -and $J.client_secret) { return $J }
        }
    }
    throw ($VendorName.ToUpper() + "_APP_NOT_CONFIGURED")
}

$Result = try {
    $App = Get-VendorApp
    if ($Request.action -eq "app") {
        @{ ok = $true; clientId = $App.client_id }
    }
    elseif ($Request.action -eq "exchange") {
        if (-not $Request.clientId -or -not $Request.code -or -not $Request.redirectUri -or -not $Request.providers) {
            throw "MISSING_FIELDS"
        }
        $Body = @{
            code          = [string]$Request.code
            client_id     = [string]$App.client_id
            client_secret = [string]$App.client_secret
            redirect_uri  = [string]$Request.redirectUri
            grant_type    = "authorization_code"
        }
        if ($Request.scope -and -not $Vendor.env) { $Body.scope = [string]$Request.scope }
        $Tok = Invoke-RestMethod -Uri $Vendor.tokenUrl -Method Post -TimeoutSec 30 -Body $Body

        if ($Vendor.env) {
            # Fournisseurs a application par variables d'environnement
            $Stored = @()
            foreach ($Provider in @($Request.providers)) {
                if ($Vendor.store -eq "slack_webhook") {
                    # Slack renvoie l'URL du webhook du canal choisi par le client
                    if (-not $Tok.ok -or -not $Tok.incoming_webhook.url) { throw "SLACK_NO_WEBHOOK" }
                    $Cred = [string]$Tok.incoming_webhook.url
                }
                else {
                    if (-not $Tok.access_token) { throw "NO_ACCESS_TOKEN" }
                    $Obj = @{ access_token = [string]$Tok.access_token; vendor = $VendorName }
                    if ($Tok.refresh_token) { $Obj.refresh_token = [string]$Tok.refresh_token }
                    if ($Tok.expires_in) { $Obj.expires_at = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [int64]$Tok.expires_in) }
                    $Cred = $Obj | ConvertTo-Json -Compress
                }
                Set-BKClientCredentialValue -ClientId $Request.clientId -Provider $Provider -PlainText $Cred
                $Stored += $Provider
            }
            @{ ok = $true; email = $null; providers = $Stored }
        }
        else {
        if (-not $Tok.refresh_token) { throw "NO_REFRESH_TOKEN" }

        $Email = $null
        try {
            $Info = Invoke-RestMethod -Uri $Vendor.userInfo -Headers @{ Authorization = "Bearer $($Tok.access_token)" } -TimeoutSec 15
            $Email = $Info.email
        } catch { }

        $Stored = @()
        foreach ($Provider in @($Request.providers)) {
            $CredObj = @{ client_id = $App.client_id; client_secret = $App.client_secret; refresh_token = $Tok.refresh_token }
            if ($Vendor.tenant) { $CredObj.tenant = $Vendor.tenant }
            Set-BKClientCredentialValue -ClientId $Request.clientId -Provider $Provider -PlainText ($CredObj | ConvertTo-Json -Compress)
            $Stored += $Provider
        }
        @{ ok = $true; email = $Email; providers = $Stored; scope = $Tok.scope }
        }
    }
    else {
        @{ ok = $false; error = "UNKNOWN_ACTION" }
    }
} catch {
    @{ ok = $false; error = $_.Exception.Message }
}

($Result | ConvertTo-Json -Compress) | Set-Content -LiteralPath $OutFile -Encoding UTF8
