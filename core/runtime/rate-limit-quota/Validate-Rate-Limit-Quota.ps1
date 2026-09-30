param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Rate Limit / Quota Config introuvable."
}

try {
    $config =
        Get-Content `
            -LiteralPath $ConfigPath `
            -Raw `
            -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Rate Limit / Quota Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Manager désactivé.")
}

if ($config.rateLimitEnabled -ne $true) {
    $errors.Add("Rate limit désactivé.")
}

if ($config.quotaEnabled -ne $true) {
    $errors.Add("Quota désactivé.")
}

if ([int]$config.windowSeconds -lt 1) {
    $errors.Add("windowSeconds invalide.")
}

if ([int]$config.defaultLimit -lt 1) {
    $errors.Add("defaultLimit invalide.")
}

foreach ($scope in @(
    "tenant",
    "client",
    "project",
    "worker",
    "connector",
    "provider"
)) {
    if ([int]$config.limits.$scope -lt 1) {
        $errors.Add(
            "Limit invalide pour scope : $scope"
        )
    }
}

if ($config.allowBurst -ne $false) {
    $errors.Add("allowBurst doit être false.")
}

if ($config.allowNegativeConsumption -ne $false) {
    $errors.Add("allowNegativeConsumption doit être false.")
}

if ($config.requireTenantIsolation -ne $true) {
    $errors.Add("Tenant isolation obligatoire.")
}

if ($config.requireClientIsolation -ne $true) {
    $errors.Add("Client isolation obligatoire.")
}

if ($config.requireProjectIsolation -ne $true) {
    $errors.Add("Project isolation obligatoire.")
}

if ($config.storeSecrets -ne $false) {
    $errors.Add("Secret storage doit être false.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION RATE LIMIT / QUOTA : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "RATE LIMIT / QUOTA CONFIG : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Rate limit : ENABLED"
Write-Host "Quota : ENABLED"
Write-Host "Window : $($config.windowSeconds)s"
Write-Host "Tenant : $($config.limits.tenant)"
Write-Host "Client : $($config.limits.client)"
Write-Host "Project : $($config.limits.project)"
Write-Host "Worker : $($config.limits.worker)"
Write-Host "Connector : $($config.limits.connector)"
Write-Host "Provider : $($config.limits.provider)"
Write-Host "Burst : FALSE"
Write-Host "Secrets : FALSE"
Write-Host "LIVE : FALSE"
exit 0