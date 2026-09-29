# =====================================================================
# BK-AI-WORKERS — Choix du fournisseur IA par defaut.
# Renvoie "OPENAI" si (1) AI-PROVIDERS.json active le LLM et OpenAI et
# (2) une cle DPAPI existe (.secrets\openai.secret.dpapi) ; sinon "NONE"
# (reponse locale de secours). Ne lit ni ne decrypte jamais la cle : la
# seule verification est l'existence du fichier. Si l'appel reel echoue
# (ex : credit epuise), le moteur (AI-PROVIDER-ENGINE-LOCAL.ps1) retombe
# lui-meme sur le traitement local — aucun blocage du parcours.
# =====================================================================

function Get-DefaultAIProvider {
    $Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
    try {
        $Config = Get-Content -LiteralPath (Join-Path $Root "core\ai\AI-PROVIDERS.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $SecretExists = Test-Path -LiteralPath (Join-Path $Root ".secrets\openai.secret.dpapi") -PathType Leaf
        $AnthropicSecret = Test-Path -LiteralPath (Join-Path $Root ".secrets\anthropic.secret.dpapi") -PathType Leaf
        if ($Config.llm_enabled -eq $true -and $Config.providers.anthropic.enabled -eq $true -and $AnthropicSecret) {
            return "ANTHROPIC"
        }
        if ($Config.llm_enabled -eq $true -and $Config.providers.openai.enabled -eq $true -and $SecretExists) {
            return "OPENAI"
        }
    }
    catch { }
    return "NONE"
}
