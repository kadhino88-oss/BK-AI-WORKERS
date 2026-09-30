param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    Write-Host "Configuration introuvable." -ForegroundColor Red
    exit 1
}

try {
    $Config = Get-Content `
        -LiteralPath $ConfigPath `
        -Raw `
        -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    Write-Host "Configuration JSON invalide." -ForegroundColor Red
    exit 1
}

$Errors = @()

if ($Config.version -ne "7H-15") {
    $Errors += "Version incorrecte."
}

if ($Config.defaults.denyByDefault -ne $true) {
    $Errors += "denyByDefault doit être TRUE."
}

if ($Config.defaults.liveExecution -ne $false) {
    $Errors += "liveExecution doit être FALSE."
}

if ($Config.financial.autonomousCommitAllowed -ne $false) {
    $Errors += "Finance autonome doit être FALSE."
}

if ($Config.financial.humanApprovalRequired -ne $true) {
    $Errors += "Finance doit exiger une validation humaine."
}

if (@($Config.financial.actions).Count -eq 0) {
    $Errors += "Aucune action financière définie."
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       7H-15 POLICY VALIDATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Version             : $($Config.version)"
Write-Host "Deny by default     : $($Config.defaults.denyByDefault)"
Write-Host "Live par défaut     : $($Config.defaults.liveExecution)"
Write-Host "Finance autonome    : $($Config.financial.autonomousCommitAllowed)"
Write-Host "Approbation finance : $($Config.financial.humanApprovalRequired)"
Write-Host "Actions financières : $(@($Config.financial.actions).Count)"

Write-Host ""

if ($Errors.Count -gt 0) {

    Write-Host "RESULTAT : FAIL" -ForegroundColor Red

    foreach ($ErrorItem in $Errors) {
        Write-Host "ERROR : $ErrorItem" -ForegroundColor Red
    }

    exit 1
}

Write-Host "RESULTAT : PASS" -ForegroundColor Green
Write-Host "Execution Policy valide." -ForegroundColor Green

exit 0