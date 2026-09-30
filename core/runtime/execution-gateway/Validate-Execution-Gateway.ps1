param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Gateway Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Gateway Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.gatewayVersion -ne "1.0") {
    $errors.Add("gatewayVersion incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Gateway doit être activé.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester désactivé.")
}

if ($config.requireCapabilityAuthorization -ne $true) {
    $errors.Add("Capability authorization obligatoire.")
}

if ($config.requireExecutionContext -ne $true) {
    $errors.Add("Execution Context obligatoire.")
}

if ($config.requirePolicyAuthorization -ne $true) {
    $errors.Add("Policy authorization obligatoire.")
}

if ($config.requireAdapterResolution -ne $true) {
    $errors.Add("Adapter resolution obligatoire.")
}

if ($config.requireCredentialReference -ne $true) {
    $errors.Add("Credential reference obligatoire.")
}

if ($config.requireHealthApproval -ne $true) {
    $errors.Add("Health approval obligatoire.")
}

if ($config.requireIdempotency -ne $true) {
    $errors.Add("Idempotency obligatoire.")
}

if ($config.allowDirectConnectorExecution -ne $false) {
    $errors.Add("Direct connector execution doit être false.")
}

if ($config.allowSecretForwarding -ne $false) {
    $errors.Add("Secret forwarding doit être false.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION EXECUTION GATEWAY : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "EXECUTION GATEWAY : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.gatewayVersion)"
Write-Host "Gateway enabled : TRUE"
Write-Host "LIVE execution : FALSE"
Write-Host "Capability required : TRUE"
Write-Host "Policy required : TRUE"
Write-Host "Adapter required : TRUE"
Write-Host "Credential reference required : TRUE"
Write-Host "Health approval required : TRUE"
Write-Host "Idempotency required : TRUE"
Write-Host "Direct execution : FALSE"
Write-Host "Secret forwarding : FALSE"
exit 0