param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Orchestrator Controller Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Orchestrator Controller Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Controller désactivé.")
}

if ($config.singleEntryPoint -ne $true) {
    $errors.Add("Single entry point doit être true.")
}

if ($config.stopOnFirstFailure -ne $true) {
    $errors.Add("stopOnFirstFailure doit être true.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if ($config.allowBypass -ne $false) {
    $errors.Add("Bypass doit être false.")
}

if ($config.allowDirectConnectorExecution -ne $false) {
    $errors.Add("Direct execution doit être false.")
}

if ($config.allowSecretPropagation -ne $false) {
    $errors.Add("Secret propagation doit être false.")
}

$required = @(
    "requireCapability",
    "requireContext",
    "requirePolicy",
    "requireAdapter",
    "requireCredential",
    "requireHealth",
    "requireExecutionControls",
    "requireGateway",
    "requireConnector",
    "requireResult",
    "requireEvent",
    "requireAudit"
)

foreach ($property in $required) {
    if ($config.$property -ne $true) {
        $errors.Add("$property doit être true.")
    }
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION ORCHESTRATOR CONTROLLER : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "ORCHESTRATOR CONTROLLER : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Enabled : TRUE"
Write-Host "Single entry point : TRUE"
Write-Host "Stop on first failure : TRUE"
Write-Host "LIVE : FALSE"
Write-Host "Bypass : FALSE"
Write-Host "Direct connector execution : FALSE"
Write-Host "Secret propagation : FALSE"
exit 0