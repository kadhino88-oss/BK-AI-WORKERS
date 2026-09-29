param(
    [string]$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
)

$ErrorActionPreference = "Stop"

$MatrixPath = Join-Path $Root "core\permissions\capability-matrix\CAPABILITY-MATRIX.json"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "     7H-10 CAPABILITY MATRIX VALIDATION" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $MatrixPath)) {
    Write-Host "ERREUR : matrice introuvable." -ForegroundColor Red
    Write-Host $MatrixPath -ForegroundColor Yellow
    exit 1
}

try {
    $MatrixRaw = Get-Content -LiteralPath $MatrixPath -Raw -Encoding UTF8
    $Matrix = $MatrixRaw | ConvertFrom-Json
}
catch {
    Write-Host "ERREUR : JSON invalide." -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Yellow
    exit 1
}

$Errors = @()
$Warnings = @()

$ExpectedWorkers = @(
    "MAYA",
    "ALEX",
    "EMMA",
    "LUCAS",
    "SAM",
    "NOAH",
    "LEA"
)

$ActualWorkers = @(
    $Matrix.workers |
    ForEach-Object { [string]$_.workerId }
)

# WORKERS

foreach ($WorkerId in $ExpectedWorkers) {

    $Worker = $Matrix.workers |
        Where-Object { $_.workerId -eq $WorkerId }

    if ($null -eq $Worker) {
        $Errors += "Worker absent : $WorkerId"
    }
}

if ($ActualWorkers.Count -ne 7) {
    $Errors += "Nombre de Workers incorrect : $($ActualWorkers.Count). Attendu : 7."
}

# REGLES DE SECURITE

if ($Matrix.globalRules.tenantIsolationRequired -ne $true) {
    $Errors += "tenantIsolationRequired doit être TRUE."
}

if ($Matrix.globalRules.clientIsolationRequired -ne $true) {
    $Errors += "clientIsolationRequired doit être TRUE."
}

if ($Matrix.globalRules.projectIsolationRequired -ne $true) {
    $Errors += "projectIsolationRequired doit être TRUE."
}

if ($Matrix.globalRules.workerAuthorizationRequired -ne $true) {
    $Errors += "workerAuthorizationRequired doit être TRUE."
}

if ($Matrix.globalRules.skillAuthorizationRequired -ne $true) {
    $Errors += "skillAuthorizationRequired doit être TRUE."
}

if ($Matrix.globalRules.toolAuthorizationRequired -ne $true) {
    $Errors += "toolAuthorizationRequired doit être TRUE."
}

if ($Matrix.globalRules.actionAuthorizationRequired -ne $true) {
    $Errors += "actionAuthorizationRequired doit être TRUE."
}

if ($Matrix.globalRules.secretExposureToWorker -ne $false) {
    $Errors += "secretExposureToWorker doit être FALSE."
}

if ($Matrix.globalRules.financialOperationsRequireHumanApproval -ne $true) {
    $Errors += "financialOperationsRequireHumanApproval doit être TRUE."
}

if ($Matrix.globalRules.irreversibleFinancialActionsAllowedAutonomously -ne $false) {
    $Errors += "Les opérations financières irréversibles doivent être interdites en autonomie."
}

if ($Matrix.globalRules.liveExecutionDefault -ne $false) {
    $Errors += "liveExecutionDefault doit être FALSE."
}

# ACTIONS

$KnownActions = @(
    "READ",
    "SEARCH",
    "REPORT",
    "CREATE",
    "UPDATE",
    "DELETE",
    "SEND",
    "PUBLISH",
    "EXECUTE",
    "FINANCIAL_PREPARE",
    "FINANCIAL_COMMIT"
)

foreach ($Worker in $Matrix.workers) {

    $WorkerId = [string]$Worker.workerId

    if ([string]::IsNullOrWhiteSpace($Worker.skillsSource)) {
        $Errors += "skillsSource absent pour $WorkerId."
    }

    if ($null -eq $Worker.capabilities) {
        $Errors += "capabilities absentes pour $WorkerId."
        continue
    }

    foreach ($Capability in @($Worker.capabilities)) {

        $Tool = [string]$Capability.tool

        if ([string]::IsNullOrWhiteSpace($Tool)) {
            $Errors += "Tool vide pour $WorkerId."
            continue
        }

        if ($null -eq $Capability.actions) {
            $Errors += "Actions absentes pour $WorkerId / $Tool."
            continue
        }

        foreach ($Action in @($Capability.actions)) {

            $ActionName = [string]$Action

            if ($KnownActions -notcontains $ActionName) {
                $Warnings += "Action non standard : $WorkerId / $Tool / $ActionName"
            }

            if ($ActionName -eq "FINANCIAL_COMMIT") {
                $Errors += "FINANCIAL_COMMIT interdit : $WorkerId / $Tool"
            }
        }
    }
}

# REGLES SPECIFIQUES

$MAYA = $Matrix.workers | Where-Object { $_.workerId -eq "MAYA" }
$LUCAS = $Matrix.workers | Where-Object { $_.workerId -eq "LUCAS" }
$SAM = $Matrix.workers | Where-Object { $_.workerId -eq "SAM" }

if ($null -ne $MAYA) {

    $MayaCRM = $MAYA.capabilities |
        Where-Object { $_.tool -eq "CRM" }

    if ($null -eq $MayaCRM) {
        $Errors += "MAYA doit disposer de CRM."
    }
}

if ($null -ne $LUCAS) {

    $LucasWordPress = $LUCAS.capabilities |
        Where-Object { $_.tool -eq "WORDPRESS" }

    if ($null -eq $LucasWordPress) {
        $Errors += "LUCAS doit disposer de WORDPRESS."
    }
    elseif (@($LucasWordPress.actions) -notcontains "PUBLISH") {
        $Errors += "LUCAS doit pouvoir utiliser WORDPRESS / PUBLISH."
    }
}

if ($null -ne $SAM) {

    $SamCRM = $SAM.capabilities |
        Where-Object { $_.tool -eq "CRM" }

    if ($null -ne $SamCRM) {
        $Errors += "SAM ne doit pas disposer de CRM."
    }
}

# RAPPORT

Write-Host ""
Write-Host "WORKERS" -ForegroundColor Cyan
Write-Host "----------------------------------------------"

foreach ($Worker in $Matrix.workers) {

    $ToolCount = @($Worker.capabilities).Count
    $ActionCount = 0

    foreach ($Capability in @($Worker.capabilities)) {
        $ActionCount += @($Capability.actions).Count
    }

    Write-Host ("{0,-8} : {1,2} tool(s) / {2,2} action(s)" -f `
        $Worker.workerId,
        $ToolCount,
        $ActionCount)
}

Write-Host ""
Write-Host "CONTROLES DE SECURITE" -ForegroundColor Cyan
Write-Host "----------------------------------------------"

Write-Host "Tenant isolation       : $($Matrix.globalRules.tenantIsolationRequired)"
Write-Host "Client isolation       : $($Matrix.globalRules.clientIsolationRequired)"
Write-Host "Project isolation      : $($Matrix.globalRules.projectIsolationRequired)"
Write-Host "Worker authorization   : $($Matrix.globalRules.workerAuthorizationRequired)"
Write-Host "Skill authorization    : $($Matrix.globalRules.skillAuthorizationRequired)"
Write-Host "Tool authorization     : $($Matrix.globalRules.toolAuthorizationRequired)"
Write-Host "Action authorization   : $($Matrix.globalRules.actionAuthorizationRequired)"
Write-Host "Secret exposure        : $($Matrix.globalRules.secretExposureToWorker)"
Write-Host "Finance approval       : $($Matrix.globalRules.financialOperationsRequireHumanApproval)"
Write-Host "Live execution default : $($Matrix.globalRules.liveExecutionDefault)"

Write-Host ""

if ($Warnings.Count -gt 0) {

    Write-Host "WARNINGS" -ForegroundColor Yellow
    Write-Host "----------------------------------------------"

    foreach ($Warning in $Warnings) {
        Write-Host "WARNING : $Warning" -ForegroundColor Yellow
    }

    Write-Host ""
}

if ($Errors.Count -gt 0) {

    Write-Host "RESULTAT : FAIL" -ForegroundColor Red
    Write-Host "----------------------------------------------"

    foreach ($ErrorItem in $Errors) {
        Write-Host "ERROR : $ErrorItem" -ForegroundColor Red
    }

    Write-Host ""
    exit 1
}

Write-Host "RESULTAT : PASS" -ForegroundColor Green
Write-Host "----------------------------------------------"
Write-Host "Capability Matrix valide."
Write-Host "Aucune erreur structurelle ou de sécurité détectée."
Write-Host ""

exit 0