# =====================================================================
# BK-AI-WORKERS — Choix du fournisseur IA par defaut.
# Renvoie "OPENAI" si (1) AI-PROVIDERS.json active le LLM et OpenAI et
# (2) une cle existe (variable BK_SECRET_*, fichier secret ou DPAPI, voir BK-Secret.ps1) ; sinon "NONE"
# (reponse locale de secours). Ne lit ni ne decrypte jamais la cle : la
# seule verification est l'existence du fichier. Si l'appel reel echoue
# (ex : credit epuise), le moteur (AI-PROVIDER-ENGINE-LOCAL.ps1) retombe
# lui-meme sur le traitement local — aucun blocage du parcours.
# =====================================================================

. (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/ai/BK-Secret.ps1")

function Get-DefaultAIProvider {
    $Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }
    try {
        $Config = Get-Content -LiteralPath (Join-Path $Root "core/ai/AI-PROVIDERS.json") -Raw -Encoding UTF8 | ConvertFrom-Json
        $SecretExists = Test-BKSecret -Name "openai"
        $AnthropicSecret = Test-BKSecret -Name "anthropic"
        # Plan de moteurs (2026-10-25, dashboard/provider_router.py) : le serveur a choisi la chaine de moteurs de CETTE mission (Claude, moteur local, hote suisse,
        # cle du client). On passe alors par l'executeur de chaine meme sans cle Anthropic sur le serveur (un essai gratuit tourne sur le modele local) ;
        # c'est lui qui dit quel moteur a repondu. Sans plan : exactement le choix d'avant.
        if (-not [string]::IsNullOrWhiteSpace($env:BK_ENGINE_PLAN) -and $Config.llm_enabled -eq $true -and $Config.providers.anthropic.enabled -eq $true) {
            return "ANTHROPIC"
        }
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
