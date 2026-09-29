# =====================================================================
# BK-AI-WORKERS — Pont d'envoi d'emails transactionnels (mot de passe
# oublie, etc.) via l'API Gmail, depuis le compte Google du PROPRIETAIRE
# deja connecte (espace CLI-DASHBOARD, provider "gmail", permission
# gmail.compose). Utilise seulement quand aucun SMTP dedie n'est configure
# (variables BK_SMTP_*, voir mailer.py). Parametres par -InFile (JSON),
# resultat dans -OutFile ; aucune valeur interpolee dans une commande, le
# secret ne quitte jamais ce processus.
#   { "to": "...", "subject": "...", "html": "...", "fromName": "..." }
# =====================================================================

param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Off
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
. (Join-Path $Root "core/connectors/Client-Credential-Store.ps1")

$Request = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json

function ConvertTo-Base64Url([byte[]]$Bytes) {
    return [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$Result = try {
    $To = [string]$Request.to
    if ($To -notmatch '^[^@\s<>",;]+@[^@\s<>",;]+\.[^@\s<>",;]{2,}$') { throw "INVALID_RECIPIENT" }
    if (-not (Test-BKClientCredential -ClientId "CLI-DASHBOARD" -Provider "gmail")) { throw "OWNER_GMAIL_NOT_CONNECTED" }
    $Cred = (Get-BKClientCredentialValue -ClientId "CLI-DASHBOARD" -Provider "gmail") | ConvertFrom-Json
    if (-not $Cred.refresh_token) { throw "OWNER_GMAIL_NOT_CONNECTED" }

    $Tok = Invoke-RestMethod -Uri "https://oauth2.googleapis.com/token" -Method Post -TimeoutSec 30 -Body @{
        client_id = [string]$Cred.client_id; client_secret = [string]$Cred.client_secret
        refresh_token = [string]$Cred.refresh_token; grant_type = "refresh_token"
    }
    $Auth = @{ Authorization = "Bearer $($Tok.access_token)" }
    $Profile = Invoke-RestMethod -Uri "https://gmail.googleapis.com/gmail/v1/users/me/profile" -Headers $Auth -TimeoutSec 20
    $FromAddr = [string]$Profile.emailAddress
    if ($FromAddr -notmatch '^[^@\s<>",;]+@[^@\s<>",;]+$') { throw "BAD_SENDER" }
    # Adresse d'envoi professionnelle (ex. contact@bk-entreprise.com) : doit etre declaree
    # comme alias "Envoyer en tant que" dans les parametres Gmail ; sinon Gmail la remplace
    # automatiquement par l'adresse du compte, sans erreur.
    $Alias = [string]$env:BK_MAIL_FROM
    $ReplyTo = ""
    if ($Alias -match '^[^@\s<>",;]+@[^@\s<>",;]+\.[^@\s<>",;]{2,}$') { $FromAddr = $Alias; $ReplyTo = "Reply-To: $Alias`r`n" }

    $FromName = ([string]$Request.fromName) -replace '[\r\n"<>]', ''
    if (-not $FromName) { $FromName = "BK-AI-WORKERS" }
    $Subject = ([string]$Request.subject) -replace '[\r\n]', ' '
    $EncSubject = "=?UTF-8?B?" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Subject)) + "?="
    $EncFrom = "=?UTF-8?B?" + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($FromName)) + "?= <$FromAddr>"
    $Body64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$Request.html), 'InsertLineBreaks')

    $Mime = "From: $EncFrom`r`n${ReplyTo}To: $To`r`nSubject: $EncSubject`r`nMIME-Version: 1.0`r`nContent-Type: text/html; charset=UTF-8`r`nContent-Transfer-Encoding: base64`r`n`r`n$Body64"
    $Raw = ConvertTo-Base64Url ([Text.Encoding]::UTF8.GetBytes($Mime))
    Invoke-RestMethod -Uri "https://gmail.googleapis.com/gmail/v1/users/me/messages/send" -Method Post -Headers $Auth `
        -ContentType "application/json" -Body (@{ raw = $Raw } | ConvertTo-Json -Compress) -TimeoutSec 30 | Out-Null
    @{ ok = $true }
} catch {
    @{ ok = $false; error = $_.Exception.Message }
}

($Result | ConvertTo-Json -Compress) | Set-Content -LiteralPath $OutFile -Encoding UTF8
