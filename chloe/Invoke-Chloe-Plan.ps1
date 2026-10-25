[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$InFile,
    [Parameter(Mandatory=$true)][string]$OutFile
)
# =====================================================================
# CHLOE - point d'entree du planificateur de projet (2026-10-25). Appele par le moteur de projets pour l'etape « plan » (et « replan »), a la place du
# lanceur d'etape generique : un sous-processus qui se termine, un fichier d'entree, un fichier de sortie, AUCUN secret dans l'un ni dans l'autre.
#
#   pwsh -NoProfile -File chloe/Invoke-Chloe-Plan.ps1 -InFile <plan-input.json> -OutFile <plan-result.json>
#
# Entree (BK-CHLOE-PLAN-INPUT-V1) :
#   { "goal": "...", "language": "fr", "clientId": "CLI-CUST-...",
#     "scope": { "chloe": true, "allowed": ["lea", ...], "denied": [{ "workerId": "clara", "reason": "..." }], "hireOffer": true },   (dashboard/chloe_scope.py)
#     "usage": { "allowedNow": 120, "binding": "session", "session": { "remaining": 120 }, "week": { "remaining": 400 }, "month": { "remaining": 800 }, "creditCostChf": 0.0375 },
#     "recipesBlock": "", "inputs": ["data/prospects.csv"], "collaboration": "PARALLEL" | "CHAIN" }
# Sortie (BK-CHLOE-PLAN-RESULT-V1) :
#   { "ok": true, "source": "model" | "fallback", "plan": { BK-PROJECT-PLAN-V1 + delegation + unassignable + triage }, "errors": [], "warnings": [],
#     "usage": { input_tokens, output_tokens, api_calls, estimated_cost_usd, estimated_cost_chf }, "attempts": 1, "model": "...", "fallbackReason": "" }
# Codes de sortie : 0 = resultat ecrit (lire ok) ; 10 = entree invalide ; 20 = erreur interne. Le plan est ensuite valide DE NOUVEAU par le moteur
# (projects.validate_plan) : la validation de ce script n'est qu'une premiere ligne de defense, pas la seule.
# =====================================================================
$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) { $PSDefaultParameterValues["ConvertFrom-Json:DateKind"] = "String" }
$Root = if ($env:BK_ROOT) { $env:BK_ROOT } else { Split-Path -Parent $PSScriptRoot }
. (Join-Path $Root "core/ai/BK-Secret.ps1")
foreach ($Helper in @("Chloe-Common.ps1", "Chloe-LegacyRouting.ps1", "Chloe-Router.ps1", "Chloe-Planner.ps1")) { . (Join-Path $PSScriptRoot $Helper) }

function Write-PlanOut($Object) {
    $Dir = Split-Path -Parent $OutFile
    if ($Dir -and -not (Test-Path -LiteralPath $Dir)) { New-Item -ItemType Directory -Path $Dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($OutFile, ($Object | ConvertTo-Json -Depth 20), [System.Text.UTF8Encoding]::new($false))
}

try {
    $In = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $Goal = (Remove-BKControlChars -Text ([string](Get-BKProp $In "goal" ""))).Trim()
    $Scope = Get-BKProp $In "scope" $null
    if ($Goal.Length -lt 3 -or $Goal.Length -gt 4000 -or $null -eq $Scope) {
        Write-PlanOut ([ordered]@{ schema = "BK-CHLOE-PLAN-RESULT-V1"; ok = $false; error = "INPUT_INVALID"; detail = "goal (3 a 4000 caracteres) et scope sont requis." })
        exit 10
    }
    $ClientId = [string](Get-BKProp $In "clientId" "")
    if ($ClientId -and $ClientId -notmatch '^[A-Za-z0-9_-]{1,64}$') {
        Write-PlanOut ([ordered]@{ schema = "BK-CHLOE-PLAN-RESULT-V1"; ok = $false; error = "INPUT_INVALID"; detail = "clientId invalide." })
        exit 10
    }
    $Language = ([string](Get-BKProp $In "language" "")).Trim().ToLowerInvariant()
    if ($Language -notmatch '^[a-z]{2,3}(-[a-z]{2,4})?$') { $Language = "" }
    $Inputs = @(@(Get-BKProp $In "inputs" @()) | ForEach-Object { [string]$_ } | Where-Object { Test-BKProjectPath $_ } | Select-Object -First 10)
    $Chain = ([string](Get-BKProp $In "collaboration" "PARALLEL")).ToUpperInvariant() -eq "CHAIN"
    $R = Invoke-BKChloePlan -Goal $Goal -Root $Root -Scope $Scope -Usage (Get-BKProp $In "usage" $null) -Language $Language -ClientId $ClientId `
        -RecipesBlock ([string](Get-BKProp $In "recipesBlock" "")) -InputsNote ($Inputs -join "`n") -Chain:$Chain
    Write-PlanOut ([ordered]@{
        schema = "BK-CHLOE-PLAN-RESULT-V1"; ok = [bool]$R.Ok; source = $R.Source; plan = $R.Plan; errors = @($R.Errors); warnings = @($R.Warnings)
        usage = $R.Usage; attempts = $R.Attempts; model = $R.Model; fallbackReason = $R.FallbackReason
    })
    exit 0
}
catch {
    Write-PlanOut ([ordered]@{ schema = "BK-CHLOE-PLAN-RESULT-V1"; ok = $false; error = "INTERNAL"; detail = (Limit-BKText -Text ([string]$_.Exception.Message) -Max 300) })
    exit 20
}
