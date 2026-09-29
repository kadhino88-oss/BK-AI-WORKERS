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

. (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/ai/BK-Secret.ps1")

function Test-SlackConfigured {
    return (Test-BKSecret -Name "slack")
}

function Get-SlackWebhookUrl {
    if (-not (Test-SlackConfigured)) {
        throw "SLACK_CREDENTIAL_NOT_CONFIGURED"
    }

    $Url = Get-BKSecretValue -Name "slack"
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
    Poste REELLEMENT un message dans le canal Slack lie au webhook
    configure. A n'appeler qu'APRES le passage par le pipeline
    d'autorisation existant (gate d'autonomie -> verification Chloe pour
    toute action classee SEND/PUBLISH) : cette fonction ne fait aucune
    verification d'autonomie elle-meme, elle execute une decision deja
    prise en amont.
    #>
    param(
        [Parameter(Mandatory=$true)][string]$Text,
        [string]$WorkerName = "BK-AI-WORKERS"
    )

    if (-not (Test-SlackConfigured)) {
        return [pscustomobject]@{
            Status = "NOT_CONFIGURED"
            Detail = "Aucun webhook Slack enregistre. Voir .secrets\Store-Credential.ps1 -Provider slack."
        }
    }

    try {
        $WebhookUrl = Get-SlackWebhookUrl
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
