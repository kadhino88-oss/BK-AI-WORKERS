# Prompt systeme commun aux adaptateurs LLM : construit depuis l'identite
# reelle du Worker (role, personnalite, style) et, si disponible, du
# profil entreprise du client (saisi a l'onboarding, un fichier par
# ClientId dans core\profile\data\).

function Get-WorkerSystemPrompt {
    param(
        [Parameter(Mandatory=$true)][string]$WorkerId,
        [string]$ClientId = ""
    )

    $ProjectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
    $IdentityPath = Join-Path $ProjectRoot ("workers\" + $WorkerId.ToLowerInvariant() + "\identity\identity.json")
    $WorkerName = $WorkerId; $Role = ""; $Personality = ""; $Style = ""
    if (Test-Path -LiteralPath $IdentityPath -PathType Leaf) {
        try {
            $Ident = Get-Content -LiteralPath $IdentityPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $WorkerName = $Ident.name; $Role = $Ident.role; $Personality = $Ident.personality; $Style = $Ident.communication_style
        } catch { }
    }

    $CompanyBlock = ""
    if ($ClientId -match '^[A-Za-z0-9_-]+$') {
        $ProfilePath = Join-Path $ProjectRoot ("core\profile\data\" + $ClientId + ".json")
        if (Test-Path -LiteralPath $ProfilePath -PathType Leaf) {
            try {
                $P = Get-Content -LiteralPath $ProfilePath -Raw -Encoding UTF8 | ConvertFrom-Json
                $Lines = @()
                if ($P.companyName) { $Lines += "- Entreprise : $($P.companyName)" }
                if ($P.sector)      { $Lines += "- Secteur : $($P.sector)" }
                if ($P.description) { $Lines += "- Activite : $($P.description)" }
                if ($Lines.Count -gt 0) { $CompanyBlock = "`nContexte du client (a utiliser, ne pas le redemander) :`n" + ($Lines -join "`n") + "`n" }
            } catch { }
        }
    }

    return @"
Tu es $WorkerName, $Role, un Worker IA de la plateforme BK-AI-WORKERS (BK Entreprise, Geneve, Suisse).
Personnalite : $Personality
Style : $Style
$CompanyBlock
Reponds toujours en francais, de facon professionnelle, concrete et directement exploitable par un dirigeant de PME suisse (montants en CHF si pertinent).
Livre un vrai resultat de travail (plan, liste, brouillon, analyse) plutot qu'un simple conseil general. Sois structure et concis.
Tu prepares et recommandes : tu n'executes aucune action reelle (envoi, publication, paiement) - ces actions sont validees par un humain.
REGLE PRINCIPALE : livre TOUT DE SUITE un resultat complet et utilisable. Ne commence jamais par poser des questions. Si une information manque, fais des hypotheses raisonnables, indique-les en une ligne ("Hypotheses : ..."), puis livre. Termine par 2 ou 3 questions maximum pour affiner la prochaine version. Ne presente jamais un chiffre invente comme un fait.
"@
}
