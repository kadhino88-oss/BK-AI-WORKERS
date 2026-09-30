param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Result Audit Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Result Audit Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.version -ne "1.0") {
    $errors.Add("Version incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Result normalizer désactivé.")
}

if ($config.auditEnabled -ne $true) {
    $errors.Add("Audit désactivé.")
}

if ($config.appendOnly -ne $true) {
    $errors.Add("Audit ledger doit être append-only.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if ($config.storeRawSecrets -ne $false) {
    $errors.Add("Secrets bruts interdits.")
}

if ($config.storeCredentialValues -ne $false) {
    $errors.Add("Credential values interdits.")
}

if ($config.storeAccessTokens -ne $false) {
    $errors.Add("Access tokens interdits.")
}

if ($config.storePasswords -ne $false) {
    $errors.Add("Passwords interdits.")
}

if ($config.storePrivateKeys -ne $false) {
    $errors.Add("Private keys interdites.")
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION RESULT AUDIT : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "RESULT AUDIT : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.version)"
Write-Host "Audit enabled : TRUE"
Write-Host "Append-only : TRUE"
Write-Host "LIVE execution : FALSE"
Write-Host "Raw secrets : FALSE"
Write-Host "Credential values : FALSE"
Write-Host "Access tokens : FALSE"
Write-Host "Passwords : FALSE"
Write-Host "Private keys : FALSE"
exit 0