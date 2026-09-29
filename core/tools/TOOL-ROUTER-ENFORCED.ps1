param(
    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$SkillId,

    [Parameter(Mandatory = $true)]
    [string]$ToolId,

    [Parameter(Mandatory = $true)]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [string]$Mode = "SIMULATION",

    [switch]$FinancialRequested
)

$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$EnforcerPath = Join-Path $Root "core\permissions\capability-matrix\CAPABILITY-ENFORCER.ps1"

if (-not (Test-Path -LiteralPath $EnforcerPath)) {
    throw "CAPABILITY-ENFORCER.ps1 introuvable."
}

$Decision = & $EnforcerPath `
    -WorkerId $WorkerId `
    -SkillId $SkillId `
    -ToolId $ToolId `
    -Action $Action `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -Mode $Mode `
    -FinancialRequested:$FinancialRequested

if ($null -eq $Decision) {
    throw "Aucune decision de capability retournee."
}

$Decision

if ($Decision.authorized -ne $true) {
    exit 10
}

exit 0