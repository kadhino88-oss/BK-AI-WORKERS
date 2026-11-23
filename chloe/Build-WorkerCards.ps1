# =====================================================================
# CHLOE - genere les CARTES des Workers (core/projects/WORKER-CARDS.json), lues par le routeur et le planificateur de Chloe
# (docs/AUTONOMY-ENGINE.md, section 6c.2). Jamais ecrit a la main : un test regenere le fichier et compare (tests/chloe-delegation).
#
#   pwsh -NoProfile -File chloe/Build-WorkerCards.ps1            ecrit core/projects/WORKER-CARDS.json
#   pwsh -NoProfile -File chloe/Build-WorkerCards.ps1 -Check     ne change rien ; code de sortie 1 si le fichier n'est plus a jour
#
# Sources (aucune nouvelle invention) :
#   - workers/<id>/identity/identity.json      nom et role
#   - workers/<id>/install-profile.json        services (libelles = "can") et connecteurs
#   - orchestrator/worker-routing.json         mots-cles de routage
#   - chloe/identity/playbook.md, bloc DEPARTAGES   "notFor" : ce qui releve d'un AUTRE Worker (paires "domaine : worker")
#   - workers/<id>/recipes/*.json              recettes (chantier recettes) : identifiants "<worker>/<slug>"
# Atlas (trading personnel du proprietaire, excluded_from_routing) n'y figure jamais.
# =====================================================================
[CmdletBinding()]
param(
    [string]$Root = "",
    [string]$OutFile = "",
    [switch]$Check
)
$ErrorActionPreference = "Stop"
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { Split-Path -Parent $PSScriptRoot } }
if ([string]::IsNullOrWhiteSpace($OutFile)) { $OutFile = Join-Path $Root "core/projects/WORKER-CARDS.json" }

function Get-Utf8Text([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $Text = [System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false)).TrimStart([char]0xFEFF)
    # Keep the generated source hash identical on Windows (CRLF) and Linux (LF).
    return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

$Routing = (Get-Utf8Text (Join-Path $Root "orchestrator/worker-routing.json")) | ConvertFrom-Json
$Excluded = @($Routing.excluded_from_routing)
$Ids = @($Routing.workers.PSObject.Properties.Name | Where-Object { $Excluded -notcontains $_ } | Sort-Object)

# ---- DEPARTAGES : "domaine : worker." (une ou plusieurs paires par ligne) -> notFor des autres Workers de la ligne
$Playbook = Get-Utf8Text (Join-Path $Root "chloe/identity/playbook.md")
$NotFor = @{}
foreach ($Id in $Ids) { $NotFor[$Id] = [System.Collections.Generic.List[string]]::new() }
$DepartageText = ""
if ($Playbook) {
    $InBlock = $false
    foreach ($Line in ($Playbook -split "`r?`n")) {
        if ($Line -match '^D[ÉE]PARTAGES') { $InBlock = $true; continue }
        if ($InBlock -and [string]::IsNullOrWhiteSpace($Line)) { break }
        if (-not $InBlock -or $Line -notmatch '^\s*-\s') { continue }
        $DepartageText += $Line + "`n"
        $Pairs = @()
        foreach ($Sentence in ([regex]::Split(($Line -replace '^\s*-\s*', ''), '\.\s+'))) {
            $M = [regex]::Match($Sentence, '^(?<cap>.+?)\s*:\s*(?<id>[a-z]{2,20})\b')
            if ($M.Success -and ($Ids -contains $M.Groups["id"].Value)) { $Pairs += [pscustomobject]@{ Cap = $M.Groups["cap"].Value.Trim(); Id = $M.Groups["id"].Value } }
        }
        foreach ($P in $Pairs) {
            foreach ($Q in $Pairs) {
                if ($Q.Id -ne $P.Id) {
                    $Entry = "$($Q.Cap) ($($Q.Id))"
                    if (-not $NotFor[$P.Id].Contains($Entry)) { $NotFor[$P.Id].Add($Entry) }
                }
            }
        }
    }
}

$Cards = @()
$HashInput = [System.Text.StringBuilder]::new()
[void]$HashInput.Append($DepartageText)
foreach ($Id in $Ids) {
    $IdentityText = Get-Utf8Text (Join-Path $Root "workers/$Id/identity/identity.json")
    $ProfileText = Get-Utf8Text (Join-Path $Root "workers/$Id/install-profile.json")
    [void]$HashInput.Append($IdentityText).Append($ProfileText).Append(($Routing.workers.PSObject.Properties[$Id].Value | ConvertTo-Json -Depth 4 -Compress))
    $Name = $Id.Substring(0, 1).ToUpperInvariant() + $Id.Substring(1)
    $Role = ""
    if ($IdentityText) { $Ident = $IdentityText | ConvertFrom-Json; if ($Ident.name) { $Name = [string]$Ident.name }; if ($Ident.role) { $Role = [string]$Ident.role } }
    $Can = @()
    $Connectors = [System.Collections.Generic.SortedSet[string]]::new()
    if ($ProfileText) {
        $Profile = $ProfileText | ConvertFrom-Json
        foreach ($S in @($Profile.services)) {
            if ($S.label) { $Can += ([string]$S.label).Trim() }
            foreach ($C in @($S.requiredConnectors) + @($S.optionalConnectors)) { if ($C) { [void]$Connectors.Add((([string]$C) -replace '\.controlled$', '')) } }
        }
    }
    $RecipeDir = Join-Path $Root "workers/$Id/recipes"
    $Recipes = @()
    if (Test-Path -LiteralPath $RecipeDir -PathType Container) {
        $Recipes = @(Get-ChildItem -LiteralPath $RecipeDir -Filter "*.json" -File | Sort-Object Name | ForEach-Object { "$Id/" + $_.BaseName })
        foreach ($R in $Recipes) { [void]$HashInput.Append($R) }
    }
    $Cards += [ordered]@{
        id = $Id
        name = $Name
        role = $Role
        can = @($Can | Select-Object -First 6 | ForEach-Object { if ($_.Length -gt 110) { $_.Substring(0, 107).TrimEnd() + "..." } else { $_ } })
        notFor = @($NotFor[$Id] | Select-Object -First 6)
        connectors = @($Connectors)
        recipes = @($Recipes)
        keywords = @($Routing.workers.PSObject.Properties[$Id].Value.primary | Select-Object -First 12)
        # Valeur par defaut identique pour tous tant que les mesures reelles (docs/COST-LEDGER.md) n'ont pas affine le cout d'une etape par Worker.
        typicalStepCredits = @(4, 12)
    }
}

$Sha = [System.Security.Cryptography.SHA256]::HashData([System.Text.Encoding]::UTF8.GetBytes($HashInput.ToString()))
$Doc = [ordered]@{
    schema = "BK-WORKER-CARDS-V1"
    generatedBy = "chloe/Build-WorkerCards.ps1"
    sourcesSha256 = (($Sha | ForEach-Object { $_.ToString("x2") }) -join "")
    cards = @($Cards)
}
$Json = (($Doc | ConvertTo-Json -Depth 6) -replace "`r`n", "`n") + "`n"

if ($Check) {
    $Current = if (Test-Path -LiteralPath $OutFile -PathType Leaf) { ([System.IO.File]::ReadAllText($OutFile, [System.Text.UTF8Encoding]::new($false)) -replace "`r`n", "`n") } else { "" }
    if ($Current -eq $Json) { Write-Output "WORKER-CARDS.json est a jour ($($Cards.Count) cartes)."; exit 0 }
    Write-Output "WORKER-CARDS.json n'est plus a jour : relancez chloe/Build-WorkerCards.ps1."
    exit 1
}
$Dir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutFile, $Json, [System.Text.UTF8Encoding]::new($false))
Write-Output "$($Cards.Count) cartes ecrites dans $OutFile"
