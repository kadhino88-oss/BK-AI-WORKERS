param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Health Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Health Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.healthVersion -ne "1.0") {
    $errors.Add("healthVersion incorrecte.")
}

if ($config.liveHealthChecksEnabled -ne $false) {
    $errors.Add("liveHealthChecksEnabled doit rester false.")
}

if ($config.retry.enabled -ne $true) {
    $errors.Add("retry.enabled doit être true.")
}

if ([int]$config.retry.maxAttempts -lt 1) {
    $errors.Add("maxAttempts doit être supérieur à 0.")
}

if ($config.circuitBreaker.enabled -ne $true) {
    $errors.Add("circuitBreaker.enabled doit être true.")
}

if ([int]$config.circuitBreaker.failureThreshold -lt 1) {
    $errors.Add("failureThreshold doit être supérieur à 0.")
}

if (-not $config.connectors) {
    $errors.Add("Aucun connector de health enregistré.")
}

$allowedStates = @(
    "HEALTHY",
    "DEGRADED",
    "UNAVAILABLE",
    "DISABLED",
    "UNKNOWN"
)

foreach ($connector in $config.connectors) {

    if ([string]::IsNullOrWhiteSpace($connector.connectorId)) {
        $errors.Add("Connector sans connectorId.")
    }

    if ($allowedStates -notcontains $connector.state) {
        $errors.Add(
            "Etat invalide pour $($connector.connectorId)."
        )
    }
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION CONNECTOR HEALTH : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "CONNECTOR HEALTH CONFIG : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.healthVersion)"
Write-Host "Connectors : $($config.connectors.Count)"
Write-Host "LIVE health checks : FALSE"
Write-Host "Retry : ENABLED"
Write-Host "Circuit breaker : ENABLED"
exit 0