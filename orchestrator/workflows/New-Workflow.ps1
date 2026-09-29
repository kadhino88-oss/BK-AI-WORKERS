param(
    [Parameter(Mandatory = $true)]
    [string]$Objective,

    [string]$Client = "bk-entreprise",

    [string]$Project = "general"
)

$ErrorActionPreference = "Stop"

# ============================================================
# MULTI-WORKER WORKFLOW ENGINE
# PHASE 4D — SIMULATION ONLY
# ============================================================

$WorkflowDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not (Test-Path $WorkflowDirectory)) {
    New-Item -ItemType Directory -Path $WorkflowDirectory -Force | Out-Null
}

# ------------------------------------------------------------
# Génération d'un identifiant unique
# ------------------------------------------------------------

$WorkflowId = "WF-" + (Get-Date -Format "yyyyMMdd-HHmmss-fff")

# ------------------------------------------------------------
# Nettoyage des valeurs
# ------------------------------------------------------------

$Objective = $Objective.Trim()
$Client = $Client.Trim()
$Project = $Project.Trim()

# ------------------------------------------------------------
# Détection du type de workflow
# ------------------------------------------------------------

$ObjectiveLower = $Objective.ToLowerInvariant()

if (
    $ObjectiveLower -match "campagne" -or
    $ObjectiveLower -match "lancement" -or
    $ObjectiveLower -match "nouveau service" -or
    $ObjectiveLower -match "nouvelle offre" -or
    $ObjectiveLower -match "service ia"
) {
    $WorkflowType = "MARKETING_LAUNCH"
}
elseif (
    $ObjectiveLower -match "site" -or
    $ObjectiveLower -match "landing" -or
    $ObjectiveLower -match "seo"
) {
    $WorkflowType = "WEB_SEO"
}
elseif (
    $ObjectiveLower -match "prospection" -or
    $ObjectiveLower -match "prospects" -or
    $ObjectiveLower -match "vente" -or
    $ObjectiveLower -match "commercial"
) {
    $WorkflowType = "SALES"
}
elseif (
    $ObjectiveLower -match "contenu" -or
    $ObjectiveLower -match "instagram" -or
    $ObjectiveLower -match "réseaux" -or
    $ObjectiveLower -match "social"
) {
    $WorkflowType = "CONTENT_SOCIAL"
}
else {
    $WorkflowType = "GENERAL"
}

# ------------------------------------------------------------
# Construction des tâches
# ------------------------------------------------------------

$Tasks = @()

# Tâche MAYA
$Tasks += [ordered]@{
    id          = "TASK-001"
    worker      = "MAYA"
    title       = "Stratégie marketing"
    description = "Définir la stratégie, le positionnement, la cible, les objectifs et le plan d'action."
    status      = "READY"
    depends_on  = @()
}

# Tâche ALEX
$Tasks += [ordered]@{
    id          = "TASK-002"
    worker      = "ALEX"
    title       = "Prospection"
    description = "Identifier, qualifier et organiser les prospects correspondant à l'offre."
    status      = "PENDING"
    depends_on  = @("TASK-001")
}

# Tâche EMMA
$Tasks += [ordered]@{
    id          = "TASK-003"
    worker      = "EMMA"
    title       = "Contenu"
    description = "Préparer les contenus marketing, publications et messages commerciaux."
    status      = "PENDING"
    depends_on  = @("TASK-001")
}

# Tâche LEA
$Tasks += [ordered]@{
    id          = "TASK-004"
    worker      = "LEA"
    title       = "Design"
    description = "Créer les éléments visuels nécessaires à la campagne et à la communication."
    status      = "PENDING"
    depends_on  = @("TASK-001")
}

# Tâche LUCAS
$Tasks += [ordered]@{
    id          = "TASK-005"
    worker      = "LUCAS"
    title       = "Landing page"
    description = "Préparer ou optimiser la landing page, le SEO et les performances techniques."
    status      = "PENDING"
    depends_on  = @("TASK-001", "TASK-003", "TASK-004")
}

# Tâche SAM
$Tasks += [ordered]@{
    id          = "TASK-006"
    worker      = "SAM"
    title       = "Sécurité"
    description = "Contrôler la sécurité, les permissions, les accès et les risques techniques."
    status      = "PENDING"
    depends_on  = @("TASK-005")
}

# ------------------------------------------------------------
# Workflow complet
# ------------------------------------------------------------

$Workflow = [ordered]@{
    workflow_id = $WorkflowId
    created_at  = (Get-Date).ToString("o")

    mode        = "SIMULATION"
    execution   = "SIMULATION_ONLY"

    status      = "READY"

    client      = $Client
    project     = $Project

    objective   = $Objective
    type        = $WorkflowType

    financial_authority = "KADER"

    financial_actions = [ordered]@{
        workers_allowed = $false
        owner           = "KADER"
        approval        = "KADER_APPROVAL"
    }

    tasks = $Tasks

    final_step = [ordered]@{
        id          = "TASK-007"
        worker      = "ORCHESTRATOR"
        title       = "Rapport final"
        description = "Compiler les résultats de tous les Workers et produire le rapport final."
        status      = "PENDING"
        depends_on  = @(
            "TASK-002",
            "TASK-003",
            "TASK-004",
            "TASK-005",
            "TASK-006"
        )
    }

    safety = [ordered]@{
        external_actions = $false
        financial_actions = $false
        real_execution    = $false
    }
}

# ------------------------------------------------------------
# Conversion JSON
# ------------------------------------------------------------

$Json = $Workflow | ConvertTo-Json -Depth 20

# ------------------------------------------------------------
# Chemin du fichier
# IMPORTANT :
# On construit le chemin directement à partir du dossier,
# et NON à partir de l'objet OrderedDictionary.
# ------------------------------------------------------------

$WorkflowFileName = "$WorkflowId.json"

$WorkflowPath = Join-Path -Path $WorkflowDirectory -ChildPath $WorkflowFileName

# ------------------------------------------------------------
# Écriture du fichier
# ------------------------------------------------------------

Set-Content `
    -Path $WorkflowPath `
    -Value $Json `
    -Encoding UTF8

# ------------------------------------------------------------
# Vérification du fichier
# ------------------------------------------------------------

if (-not (Test-Path $WorkflowPath)) {
    Write-Host ""
    Write-Host "ERREUR : le fichier workflow n'a pas été créé." -ForegroundColor Red
    exit 1
}

try {
    $Validation = Get-Content -Path $WorkflowPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host ""
    Write-Host "ERREUR : le fichier JSON est invalide." -ForegroundColor Red
    exit 1
}

# ------------------------------------------------------------
# AFFICHAGE
# ------------------------------------------------------------

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host " MULTI-WORKER WORKFLOW — SIMULATION" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "WORKFLOW : $WorkflowId"
Write-Host "CLIENT   : $Client"
Write-Host "PROJECT  : $Project"
Write-Host "TYPE     : $WorkflowType"
Write-Host "STATUS   : READY"
Write-Host ""

Write-Host "PLAN D'EXECUTION :" -ForegroundColor Yellow
Write-Host ""

Write-Host "1. MAYA  → Stratégie marketing"
Write-Host "2. ALEX  → Prospection       [après MAYA]"
Write-Host "3. EMMA  → Contenu           [après MAYA]"
Write-Host "4. LÉA   → Design             [après MAYA]"
Write-Host "5. LUCAS → Landing page       [après MAYA + EMMA + LÉA]"
Write-Host "6. SAM   → Sécurité            [après LUCAS]"
Write-Host ""
Write-Host "7. ORCHESTRATEUR → Rapport final"
Write-Host ""

Write-Host "EXECUTION : SIMULATION" -ForegroundColor Green
Write-Host "Aucune action externe n'a été exécutée."
Write-Host ""

Write-Host "JSON CREE :" -ForegroundColor Green
Write-Host $WorkflowPath
Write-Host ""

Write-Host "VALIDATION JSON : OK" -ForegroundColor Green
Write-Host ""

Write-Host "============================================" -ForegroundColor Cyan
Write-Host " WORKFLOW PRET" -ForegroundColor Green
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""