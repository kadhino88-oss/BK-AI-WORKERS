# =====================================================================
# BK-AI-WORKERS — Migration unique (2026-09-24) : copie les identifiants
# globaux existants (BK_SECRET_<NOM>, variables d'environnement) vers le
# nouvel espace par client de Kader (ClientId "CLI-DASHBOARD"), pour
# qu'il devienne "un client comme un autre" dans le nouveau systeme.
# N'efface rien des variables d'environnement d'origine (elles restent,
# inutilisees par le nouveau code, jusqu'a nettoyage ulterieur volontaire).
# A LANCER SUR LE VPS.
# =====================================================================

$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "/data/app" }
. (Join-Path $Root "core/connectors/Client-Credential-Store.ps1")

$ClientId = "CLI-DASHBOARD"

# Meme liste de providers que set-connector-secrets.py + gmail/calendar/drive/gsc/anthropic.
$Providers = @(
    "slack", "trello", "asana", "monday", "zendesk", "intercom", "figma",
    "hubspot", "pipedrive", "webflow", "shopify", "woocommerce",
    "wordpress", "dropbox", "linkedin", "facebook", "instagram", "tiktok",
    "x_twitter", "meta_ads", "whatsapp_business", "gmail", "google_calendar",
    "google_drive", "google_search_console", "google_ads", "outlook_mail",
    "outlook_calendar", "teams", "onedrive", "salesforce"
)

$Migrated = 0
$Skipped = 0
foreach ($Provider in $Providers) {
    $EnvName = "BK_SECRET_" + $Provider.ToUpperInvariant()
    $Value = [Environment]::GetEnvironmentVariable($EnvName)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Skipped++
        continue
    }
    Set-BKClientCredentialValue -ClientId $ClientId -Provider $Provider -PlainText $Value
    Write-Host "  -> $Provider migre vers $ClientId"
    $Migrated++
}

Write-Host ""
Write-Host "$Migrated identifiant(s) migre(s), $Skipped ignore(s) (non configures)." -ForegroundColor Green
