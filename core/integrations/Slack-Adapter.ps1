# =====================================================================
# BK-AI-WORKERS — Adaptateur Slack (premiere integration EXTERNE reelle)
# Cle chargee en DPAPI depuis .secrets\slack.secret.dpapi (webhook Slack
# "Incoming Webhook" — jamais tapee/collee par Claude, meme convention
# que did.secret.dpapi / elevenlabs.secret.dpapi). Sans ce fichier,
# Send-SlackMessage renvoie NOT_CONFIGURED et ne tente aucun appel.
#
# Portee volontairement etroite : POST_MESSAGE uniquement (poster un
# message reel dans le canal Slack lie au webhook). Aucune lecture,
# aucun autre connecteur (CRM, paiement...) n'est touche par ce fichier.
# Ecrit le 2026-09-15, suite a l'autorisation explicite de Kader de
# construire une premiere integration reelle.
# =====================================================================

. (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/connectors/Client-Credential-Store.ps1")

function Test-SlackConfigured {
    param([Parameter(Mandatory=$true)][string]$ClientId)
    return (Test-BKClientCredential -ClientId $ClientId -Provider "slack")
}

function Get-SlackWebhookUrl {
    param([Parameter(Mandatory=$true)][string]$ClientId)
    if (-not (Test-SlackConfigured -ClientId $ClientId)) {
        throw "SLACK_CREDENTIAL_NOT_CONFIGURED"
    }

    $Url = Get-BKClientCredentialValue -ClientId $ClientId -Provider "slack"
    if ([string]::IsNullOrWhiteSpace($Url)) {
        throw "SLACK_CREDENTIAL_EMPTY"
    }
    if ($Url -notmatch '^https://hooks\.slack\.com/services/') {
        throw "SLACK_CREDENTIAL_INVALID_FORMAT"
    }
    return $Url
}

function Send-SlackMessage {
    <#
    Poste REELLEMENT un message dans le canal Slack lie au webhook DE CE
    CLIENT. A n'appeler qu'APRES le passage par le pipeline
    d'autorisation existant (gate d'autonomie -> verification Chloe pour
    toute action classee SEND/PUBLISH) : cette fonction ne fait aucune
    verification d'autonomie elle-meme, elle execute une decision deja
    prise en amont.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$ClientId,
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$WorkerName = "BK-AI-WORKERS"
    )

    if (-not (Test-SlackConfigured -ClientId $ClientId)) {
        return [pscustomobject]@{
            Status = "NOT_CONFIGURED"
            Detail = "Aucun webhook Slack enregistre pour ce compte."
        }
    }

    try {
        $WebhookUrl = Get-SlackWebhookUrl -ClientId $ClientId
        $Payload = @{
            text     = $Text
            username = $WorkerName
        } | ConvertTo-Json -Depth 5

        $Response = Invoke-RestMethod -Uri $WebhookUrl -Method Post -ContentType "application/json; charset=utf-8" -Body ([System.Text.Encoding]::UTF8.GetBytes($Payload)) -TimeoutSec 15

        return [pscustomobject]@{
            Status = "SENT"
            Detail = "Message poste reellement sur Slack."
            Live   = $true
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
