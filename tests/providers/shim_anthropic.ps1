# =====================================================================
# Faux API Anthropic POUR LES TESTS DE LA CHAINE DE MOTEURS : remplace Invoke-RestMethod pour https://api.anthropic.com/* uniquement (aucun reseau, aucun cout) ;
# tout autre appel (le faux serveur OpenAI-compatible local) est transmis a la vraie commande. A dot-sourcer dans le pilote de test.
#
#   FAKE_ANTHROPIC       JSON : liste d'etapes consommees dans l'ordre pour chaque POST /v1/messages (la derniere se repete)
#                          {"credit_error": true}             HTTP 400 « credit balance is too low » (comme l'API quand le credit est epuise)
#                          {"auth_error": true}               HTTP 401 invalid x-api-key
#                          {"timeout": true}                  delai depasse
#                          {"text": "...", "usage": [in, out]}  reponse finale
#                          {"tool_use": {...input...}, "usage": [in, out]}  appel de use_connector (puis la suite)
#   FAKE_ANTHROPIC_KEY   la cle que l'appelant doit envoyer (x-api-key) ; une autre cle donne HTTP 401
#   FAKE_ANTHROPIC_LOG   fichier JSONL : une ligne par requete {n, keyOk, model, cost_ceiling_hint}
# =====================================================================

$Global:RealIrm = Get-Command -Name Invoke-RestMethod -CommandType Cmdlet

class FakeAnthHttpException : System.Exception {
    $Response
    FakeAnthHttpException([string]$Message, [int]$Code) : base($Message) {
        $this.Response = [pscustomobject]@{ StatusCode = $Code }
    }
}

$Global:FakeAnthSteps = if ($env:FAKE_ANTHROPIC) { @($env:FAKE_ANTHROPIC | ConvertFrom-Json) } else { @() }
$Global:FakeAnthIndex = 0

function New-FakeAnthError {
    param([int]$Code, [string]$Text)
    $Body = (@{ type = "error"; error = @{ type = "invalid_request_error"; message = $Text } } | ConvertTo-Json -Compress)
    $Ex = [FakeAnthHttpException]::new("Response status code does not indicate success: $Code.", $Code)
    $Rec = [System.Management.Automation.ErrorRecord]::new($Ex, "FakeHttp$Code", [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
    $Rec.ErrorDetails = [System.Management.Automation.ErrorDetails]::new($Body)
    return $Rec
}

function Invoke-RestMethod {
    param($Uri, $Method = "GET", $Headers, $ContentType, $Body, $TimeoutSec, $MaximumRedirection, $OutFile, $Credential)
    if (([string]$Uri) -notlike "https://api.anthropic.com/*") {
        $Splat = @{}
        foreach ($K in $PSBoundParameters.Keys) { $Splat[$K] = $PSBoundParameters[$K] }
        return & $Global:RealIrm @Splat
    }
    $KeyOk = ($null -ne $Headers -and [string]$Headers["x-api-key"] -eq $env:FAKE_ANTHROPIC_KEY)
    $BodyText = if ($Body -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($Body) } else { [string]$Body }
    $Req = $BodyText | ConvertFrom-Json
    $N = $Global:FakeAnthIndex
    $Global:FakeAnthIndex++
    if ($env:FAKE_ANTHROPIC_LOG) {
        $Line = [ordered]@{ n = $N; keyOk = $KeyOk; model = [string]$Req.model; messages = @($Req.messages).Count } | ConvertTo-Json -Compress
        [System.IO.File]::AppendAllText($env:FAKE_ANTHROPIC_LOG, $Line + "`n", [System.Text.UTF8Encoding]::new($false))
    }
    if (-not $KeyOk) { throw (New-FakeAnthError 401 "invalid x-api-key") }
    $Step = if ($Global:FakeAnthSteps.Count -gt 0) { $Global:FakeAnthSteps[[Math]::Min($N, $Global:FakeAnthSteps.Count - 1)] } else { [pscustomobject]@{ text = "ok" } }
    if ($Step.credit_error) { throw (New-FakeAnthError 400 "Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits.") }
    if ($Step.auth_error) { throw (New-FakeAnthError 401 "invalid x-api-key") }
    if ($Step.timeout) { throw "The request was canceled due to the configured HttpClient.Timeout of 120 seconds elapsing." }
    $Usage = if ($Step.usage) { @{ input_tokens = [int]$Step.usage[0]; output_tokens = [int]$Step.usage[1] } } else { @{ input_tokens = 1000; output_tokens = 100 } }
    if ($Step.tool_use) {
        return [pscustomobject]@{ id = "msg_x"; type = "message"; role = "assistant"; model = [string]$Req.model; stop_reason = "tool_use"; usage = [pscustomobject]$Usage
            content = @([pscustomobject]@{ type = "tool_use"; id = "toolu_$N"; name = "use_connector"; input = $Step.tool_use }) }
    }
    return [pscustomobject]@{ id = "msg_x"; type = "message"; role = "assistant"; model = [string]$Req.model; stop_reason = "end_turn"; usage = [pscustomobject]$Usage
        content = @([pscustomobject]@{ type = "text"; text = [string]$Step.text }) }
}
