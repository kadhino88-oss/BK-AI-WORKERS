param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Execution Event Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Execution Event Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.eventBusEnabled -ne $true) {
    $errors.Add("eventBusEnabled doit être true.")
}

if ($config.auditEvents -ne $true) {
    $errors.Add("auditEvents doit être true.")
}

if ($config.appendOnly -ne $true) {
    $errors.Add("appendOnly doit être true.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if (-not $config.allowedStates) {
    $errors.Add("allowedStates absent.")
}

if (-not $config.allowedTransitions) {
    $errors.Add("allowedTransitions absent.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION EXECUTION EVENT : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "EXECUTION EVENT CONFIG : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Event Bus : ENABLED"
Write-Host "Audit events : ENABLED"
Write-Host "Append-only : TRUE"
Write-Host "States : $($config.allowedStates.Count)"
Write-Host "Transitions : $($config.allowedTransitions.Count)"
Write-Host "LIVE : FALSE"
exit 0