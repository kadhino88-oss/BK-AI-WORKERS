param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Execution Controls Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "JSON Execution Controls invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("liveExecutionEnabled doit rester false.")
}

if ($config.timeout.enabled -ne $true) {
    $errors.Add("Timeout doit être activé.")
}

if ([int]$config.timeout.minimumSeconds -lt 1) {
    $errors.Add("minimumSeconds invalide.")
}

if (
    [int]$config.timeout.maximumSeconds -lt
    [int]$config.timeout.minimumSeconds
) {
    $errors.Add("Plage de timeout invalide.")
}

if ($config.retry.enabled -ne $true) {
    $errors.Add("Retry doit être activé.")
}

if ([int]$config.retry.maxAttempts -lt 1) {
    $errors.Add("maxAttempts invalide.")
}

if ($config.idempotency.enabled -ne $true) {
    $errors.Add("Idempotency doit être activée.")
}

if ($config.idempotency.requiredForMutations -ne $true) {
    $errors.Add("Idempotency doit être requise pour les mutations.")
}

if ($errors.Count -gt 0) {
    Write-Host ""
    Write-Host "VALIDATION EXECUTION CONTROLS : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "EXECUTION CONTROLS : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Timeout : ENABLED"
Write-Host "Retry : ENABLED"
Write-Host "Idempotency : ENABLED"
Write-Host "LIVE execution : FALSE"
exit 0