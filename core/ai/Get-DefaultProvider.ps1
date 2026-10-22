# =====================================================================
# GET-DEFAULTPROVIDER.PS1 — Mode Souverain Local (2026-10-21)
# Remplace l'appel Anthropic externe par un moteur d'inférence local
# 100% autonome, sans dépendance externe, conforme nLPD.
# =====================================================================

function Get-DefaultAIProvider {
    return [pscustomobject]@{
        ProviderName = "LocalSovereign"
        Endpoint     = "http://localhost:11434/v1"
        Model        = "llama3:latest"
        LocalOnly    = $true
        Status       = "ACTIVE_SOVEREIGN"
    }
}
