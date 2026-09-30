param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Execution Queue Config introuvable."
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
    throw "Execution Queue Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Queue Manager désactivé.")
}

if ($config.queueEnabled -ne $true) {
    $errors.Add("Queue désactivée.")
}

if ($config.schedulerEnabled -ne $true) {
    $errors.Add("Scheduler désactivé.")
}

if ([int]$config.maxQueueSize -lt 1) {
    $errors.Add("maxQueueSize invalide.")
}

if ([int]$config.maxConcurrentExecutions -lt 1) {
    $errors.Add("maxConcurrentExecutions invalide.")
}

if (
    [int]$config.minimumPriority -lt 1 -or
    [int]$config.maximumPriority -lt [int]$config.minimumPriority
) {
    $errors.Add("Plage de priorité invalide.")
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

if ($config.allowSecretStorage -ne $false) {
    $errors.Add("Secret storage doit être false.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION EXECUTION QUEUE : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "EXECUTION QUEUE CONFIG : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Queue : ENABLED"
Write-Host "Scheduler : ENABLED"
Write-Host "Max queue size : $($config.maxQueueSize)"
Write-Host "Max concurrent : $($config.maxConcurrentExecutions)"
Write-Host "Priority : $($config.minimumPriority)-$($config.maximumPriority)"
Write-Host "Tenant isolation : TRUE"
Write-Host "Client isolation : TRUE"
Write-Host "Project isolation : TRUE"
Write-Host "Secrets in queue : FALSE"
Write-Host "LIVE : FALSE"
exit 0