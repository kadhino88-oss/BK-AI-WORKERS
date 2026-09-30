param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Concurrency Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Concurrency Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Concurrency Manager désactivé.")
}

if ($config.lockEnabled -ne $true) {
    $errors.Add("Lock Manager désactivé.")
}

if ($config.allowConcurrentSameKey -ne $false) {
    $errors.Add("Les exécutions concurrentes de la même clé doivent être interdites.")
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

if ($config.storeSecretsInLocks -ne $false) {
    $errors.Add("Les locks ne doivent pas contenir de secrets.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if (
    [int]$config.minimumLockSeconds -lt 1 -or
    [int]$config.maximumLockSeconds -lt [int]$config.minimumLockSeconds
) {
    $errors.Add("Plage lock invalide.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION CONCURRENCY : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "CONCURRENCY CONFIG : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Lock Manager : ENABLED"
Write-Host "Concurrent same key : FALSE"
Write-Host "Tenant isolation : TRUE"
Write-Host "Client isolation : TRUE"
Write-Host "Project isolation : TRUE"
Write-Host "Secrets in locks : FALSE"
Write-Host "LIVE : FALSE"
exit 0