param(
    [Parameter(Mandatory = $true)]
    [string]$WorkflowPath
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " WORKFLOW VALIDATION — PHASE 4D" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

# ------------------------------------------------------------
# Vérification du fichier
# ------------------------------------------------------------

if (-not (Test-Path -LiteralPath $WorkflowPath)) {
    Write-Host "ERREUR : fichier workflow introuvable." -ForegroundColor Red
    Write-Host ""
    Write-Host "Chemin recherché :"
    Write-Host $WorkflowPath
    exit 1
}

Write-Host "FICHIER :" -ForegroundColor Yellow
Write-Host $WorkflowPath
Write-Host ""

# ------------------------------------------------------------
# Lecture JSON
# ------------------------------------------------------------

try {
    $JsonContent = Get-Content -LiteralPath $WorkflowPath -Raw
    $Workflow = $JsonContent | ConvertFrom-Json
}
catch {
    Write-Host "ERREUR : JSON invalide." -ForegroundColor Red
    Write-Host $_.Exception.Message
    exit 1
}

Write-Host "JSON : VALIDE" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Vérification des champs principaux
# ------------------------------------------------------------

$RequiredFields = @(
    "workflow_id",
    "created_at",
    "mode",
    "execution",
    "status",
    "client",
    "project",
    "objective",
    "type",
    "financial_authority",
    "financial_actions",
    "tasks",
    "final_step",
    "safety"
)

$MissingFields = @()

foreach ($Field in $RequiredFields) {

    $Property = $Workflow.PSObject.Properties[$Field]

    if ($null -eq $Property) {
        $MissingFields += $Field
    }
}

if ($MissingFields.Count -gt 0) {

    Write-Host "ERREUR : champs obligatoires manquants." -ForegroundColor Red

    foreach ($Field in $MissingFields) {
        Write-Host " - $Field" -ForegroundColor Red
    }

    exit 1
}

Write-Host "STRUCTURE : VALIDE" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Vérification du mode simulation
# ------------------------------------------------------------

if ($Workflow.mode -ne "SIMULATION") {

    Write-Host "ERREUR : le workflow n'est pas en mode SIMULATION." -ForegroundColor Red
    exit 1
}

if ($Workflow.execution -ne "SIMULATION_ONLY") {

    Write-Host "ERREUR : l'exécution n'est pas SIMULATION_ONLY." -ForegroundColor Red
    exit 1
}

if ($Workflow.safety.external_actions -ne $false) {

    Write-Host "ERREUR : les actions externes ne sont pas bloquées." -ForegroundColor Red
    exit 1
}

if ($Workflow.safety.financial_actions -ne $false) {

    Write-Host "ERREUR : les actions financières ne sont pas bloquées." -ForegroundColor Red
    exit 1
}

if ($Workflow.safety.real_execution -ne $false) {

    Write-Host "ERREUR : l'exécution réelle n'est pas désactivée." -ForegroundColor Red
    exit 1
}

Write-Host "SECURITE : VALIDE" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Vérification des Workers
# ------------------------------------------------------------

$ExpectedWorkers = @(
    "MAYA",
    "ALEX",
    "EMMA",
    "LEA",
    "LUCAS",
    "SAM"
)

$FoundWorkers = @(
    $Workflow.tasks | ForEach-Object {
        $_.worker
    }
)

$WorkersOK = $true

foreach ($Worker in $ExpectedWorkers) {

    if ($FoundWorkers -notcontains $Worker) {

        Write-Host "WORKER MANQUANT : $Worker" -ForegroundColor Red
        $WorkersOK = $false
    }
}

if (-not $WorkersOK) {
    exit 1
}

Write-Host "WORKERS : 6/6 PRESENTS" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Vérification des dépendances
# ------------------------------------------------------------

$DependencyTests = @(
    @{
        Task = "TASK-002"
        DependsOn = "TASK-001"
    },
    @{
        Task = "TASK-003"
        DependsOn = "TASK-001"
    },
    @{
        Task = "TASK-004"
        DependsOn = "TASK-001"
    },
    @{
        Task = "TASK-005"
        DependsOn = "TASK-001"
    },
    @{
        Task = "TASK-005"
        DependsOn = "TASK-003"
    },
    @{
        Task = "TASK-005"
        DependsOn = "TASK-004"
    },
    @{
        Task = "TASK-006"
        DependsOn = "TASK-005"
    }
)

$DependenciesOK = $true

foreach ($Test in $DependencyTests) {

    $Task = $Workflow.tasks |
        Where-Object { $_.id -eq $Test.Task }

    if ($null -eq $Task) {

        Write-Host "TACHE INTROUVABLE : $($Test.Task)" -ForegroundColor Red
        $DependenciesOK = $false
        continue
    }

    if ($Task.depends_on -notcontains $Test.DependsOn) {

        Write-Host "DEPENDANCE MANQUANTE : $($Test.Task) -> $($Test.DependsOn)" -ForegroundColor Red
        $DependenciesOK = $false
    }
}

# ------------------------------------------------------------
# Vérification finale
# ------------------------------------------------------------

if (-not $DependenciesOK) {

    Write-Host ""
    Write-Host "DEPENDANCES : ECHEC" -ForegroundColor Red
    exit 1
}

Write-Host "DEPENDANCES : VALIDES" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Vérification du rapport final
# ------------------------------------------------------------

if ($Workflow.final_step.worker -ne "ORCHESTRATOR") {

    Write-Host "ERREUR : le rapport final n'est pas attribué à ORCHESTRATOR." -ForegroundColor Red
    exit 1
}

Write-Host "RAPPORT FINAL : VALIDE" -ForegroundColor Green
Write-Host ""

# ------------------------------------------------------------
# Résultat
# ------------------------------------------------------------

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " VALIDATION REUSSIE" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "Workflow ID : $($Workflow.workflow_id)"
Write-Host "Client      : $($Workflow.client)"
Write-Host "Projet      : $($Workflow.project)"
Write-Host "Type        : $($Workflow.type)"
Write-Host "Status      : $($Workflow.status)"
Write-Host ""

Write-Host "MODE        : SIMULATION ONLY" -ForegroundColor Yellow
Write-Host "EXTERNE     : BLOQUE"
Write-Host "FINANCE     : BLOQUE"
Write-Host "EXECUTION   : AUCUNE"
Write-Host ""

Write-Host "RESULTAT : WORKFLOW VALIDE ET PRET POUR LA SUITE." -ForegroundColor Green
Write-Host ""