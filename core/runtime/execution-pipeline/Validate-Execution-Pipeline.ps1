param(
    [Parameter(Mandatory = $true)]
    [string]$ConfigPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    throw "Pipeline Config introuvable."
}

try {
    $config =
        Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 |
        ConvertFrom-Json
}
catch {
    throw "Pipeline Config JSON invalide."
}

$errors = New-Object System.Collections.Generic.List[string]

if ($config.pipelineVersion -ne "1.0") {
    $errors.Add("pipelineVersion incorrecte.")
}

if ($config.enabled -ne $true) {
    $errors.Add("Pipeline doit être activé.")
}

if ($config.liveExecutionEnabled -ne $false) {
    $errors.Add("LIVE doit rester false.")
}

if ($config.requireAllStages -ne $true) {
    $errors.Add("Toutes les étapes doivent être obligatoires.")
}

if ($config.allowStageBypass -ne $false) {
    $errors.Add("Stage bypass doit être false.")
}

if ($config.allowSecretPropagation -ne $false) {
    $errors.Add("Secret propagation doit être false.")
}

if ($config.allowDirectConnectorExecution -ne $false) {
    $errors.Add("Direct connector execution doit être false.")
}

$expectedStages = @(
    "CAPABILITY",
    "CONTEXT",
    "POLICY",
    "ADAPTER",
    "CREDENTIAL",
    "HEALTH",
    "RETRY_TIMEOUT_IDEMPOTENCY",
    "GATEWAY",
    "CONNECTOR",
    "RESULT",
    "AUDIT"
)

foreach ($stage in $expectedStages) {
    if ($config.stages -notcontains $stage) {
        $errors.Add("Stage manquante : $stage")
    }
}

if ($errors.Count -gt 0) {

    Write-Host ""
    Write-Host "VALIDATION EXECUTION PIPELINE : FAIL" -ForegroundColor Red

    foreach ($message in $errors) {
        Write-Host "FAIL : $message" -ForegroundColor Red
    }

    exit 1
}

Write-Host ""
Write-Host "EXECUTION PIPELINE : VALIDE" -ForegroundColor Green
Write-Host "Version : $($config.pipelineVersion)"
Write-Host "Stages : $($config.stages.Count)"
Write-Host "LIVE execution : FALSE"
Write-Host "Stage bypass : FALSE"
Write-Host "Secret propagation : FALSE"
Write-Host "Direct connector execution : FALSE"
exit 0