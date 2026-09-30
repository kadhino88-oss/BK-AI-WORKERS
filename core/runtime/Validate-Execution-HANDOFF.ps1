param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ContextPath)) {
    Write-Host "CONTEXTE ABSENT" -ForegroundColor Red
    exit 1
}

try {
    $Raw = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8
    $Handoff = $Raw | ConvertFrom-Json
}
catch {
    Write-Host "HANDOFF JSON INVALIDE" -ForegroundColor Red
    exit 1
}

$Errors = @()

$Required = @(
    "schema",
    "version",
    "executionId",
    "correlationId",
    "tenantId",
    "clientId",
    "projectId",
    "workerId",
    "skillId",
    "taskId",
    "toolId",
    "action",
    "mode",
    "receivedAt",
    "sourceContext"
)

foreach ($Field in $Required) {

    if (-not ($Handoff.PSObject.Properties.Name -contains $Field)) {
        $Errors += "Champ absent : $Field"
        continue
    }

    if (
        $null -eq $Handoff.$Field -or
        (
            $Handoff.$Field -is [string] -and
            [string]::IsNullOrWhiteSpace([string]$Handoff.$Field)
        )
    ) {
        $Errors += "Champ vide : $Field"
    }
}

if ($Handoff.security.tenantIsolation -ne $true) {
    $Errors += "tenantIsolation invalide."
}

if ($Handoff.security.clientIsolation -ne $true) {
    $Errors += "clientIsolation invalide."
}

if ($Handoff.security.projectIsolation -ne $true) {
    $Errors += "projectIsolation invalide."
}

if ($Handoff.security.secretExposureToWorker -ne $false) {
    $Errors += "secretExposureToWorker doit être FALSE."
}

if ($Handoff.security.authorizationRequired -ne $true) {
    $Errors += "authorizationRequired doit être TRUE."
}

if ($Handoff.security.capabilityAlreadyChecked -ne $true) {
    $Errors += "Capability check absent."
}

if ($Handoff.runtime.handoffAccepted -ne $true) {
    $Errors += "handoffAccepted doit être TRUE."
}

if ($Handoff.runtime.executionAllowed -ne $false) {
    $Errors += "executionAllowed doit rester FALSE à ce stade."
}

if ($Handoff.financial.autonomousCommitAllowed -ne $false) {
    $Errors += "Finance autonome interdite."
}

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "       7H-14 RUNTIME HANDOFF VALIDATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "ExecutionId : $($Handoff.executionId)"
Write-Host "Correlation : $($Handoff.correlationId)"
Write-Host "Tenant      : $($Handoff.tenantId)"
Write-Host "Client      : $($Handoff.clientId)"
Write-Host "Projet      : $($Handoff.projectId)"
Write-Host "Worker      : $($Handoff.workerId)"
Write-Host "Skill       : $($Handoff.skillId)"
Write-Host "Task        : $($Handoff.taskId)"
Write-Host "Tool        : $($Handoff.toolId)"
Write-Host "Action      : $($Handoff.action)"
Write-Host "Mode        : $($Handoff.mode)"

Write-Host ""

if ($Errors.Count -gt 0) {

    Write-Host "RESULTAT : FAIL" -ForegroundColor Red
    Write-Host ""

    foreach ($ErrorItem in $Errors) {
        Write-Host "ERROR : $ErrorItem" -ForegroundColor Red
    }

    exit 1
}

Write-Host "RESULTAT : PASS" -ForegroundColor Green
Write-Host "Runtime Handoff valide." -ForegroundColor Green
Write-Host ""

exit 0