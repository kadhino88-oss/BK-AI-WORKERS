# BK AI WORKERS
# MAYA - MARKETING INTELLIGENCE ENGINE
# PHASE 7G-5
# STRUCTURED LOCAL INTELLIGENCE

param(
    [Parameter(Mandatory=$true)]
    [string]$Request,

    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$WorkerId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string]$ContextPath,

    [Parameter(Mandatory=$true)]
    [string]$MemoryPath
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$runtimePath = Join-Path $projectRoot "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MAYA - MARKETING INTELLIGENCE"
Write-Host " PHASE 7G-5"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT   : $ClientId"
Write-Host "PROJECT  : $ProjectId"
Write-Host "WORKER   : $WorkerId"
Write-Host "TASK     : $TaskId"
Write-Host ""

if ($WorkerId -ne "MAYA") {
    Write-Host "WORKER IDENTITY : INVALID"
    exit 1
}

if ([string]::IsNullOrWhiteSpace($Request)) {
    Write-Host "REQUEST : INVALID"
    exit 1
}

if (!(Test-Path -LiteralPath $ContextPath)) {
    Write-Host "CONTEXT : NOT FOUND"
    exit 1
}

if (!(Test-Path -LiteralPath $MemoryPath)) {
    Write-Host "MEMORY : NOT FOUND"
    exit 1
}

try {
    $context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
    $memory = Get-Content -LiteralPath $MemoryPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "CONTEXT / MEMORY : INVALID"
    exit 1
}

$contextClient = $context.client_id
$contextProject = $context.project_id
$contextWorker = $context.worker_id

if ([string]::IsNullOrWhiteSpace($contextClient) -and $context.context) {
    $contextClient = $context.context.client_id
    $contextProject = $context.context.project_id
    $contextWorker = $context.context.worker_id
}

if ($contextClient -ne $ClientId -or
    $contextProject -ne $ProjectId -or
    $contextWorker -ne $WorkerId) {
    Write-Host "CONTEXT IDENTITY : MISMATCH"
    exit 1
}

Write-Host "IDENTITY : VALID"
Write-Host "CONTEXT  : VALID"
Write-Host "MEMORY   : LOADED"

function Get-ObjectiveType {
    param([string]$Text)

    $t = $Text.ToLowerInvariant()

    if ($t -match "lancement|lancer|nouveau service|nouveau produit|launch") {
        return "PRODUCT_OR_SERVICE_LAUNCH"
    }

    if ($t -match "prospect|acquisition|client|vente|lead") {
        return "CUSTOMER_ACQUISITION"
    }

    if ($t -match "publicité|ads|meta|google|campagne payante") {
        return "PAID_MARKETING"
    }

    return "GENERAL_MARKETING"
}

function Get-StringValue {
    param([string]$Type)

    switch ($Type) {
        "PRODUCT_OR_SERVICE_LAUNCH" {
            return "Transformer le nouveau service en offre clairement positionnée, visible et simple à acheter."
        }
        "CUSTOMER_ACQUISITION" {
            return "Construire un système d'acquisition régulier de prospects qualifiés et les convertir en clients."
        }
        "PAID_MARKETING" {
            return "Construire une campagne mesurable, tester les audiences et optimiser le coût d'acquisition."
        }
        default {
            return "Structurer une stratégie marketing cohérente, mesurable et orientée résultats."
        }
    }
}

$objectiveType = Get-ObjectiveType -Text $Request

$strategy = [ordered]@{
    objective_type = $objectiveType

    positioning = @{
        objective = Get-StringValue -Type $objectiveType
        principle = "Positionner clairement l'offre autour d'un problème concret, d'un résultat mesurable et d'une promesse crédible."
    }

    target = @{
        primary = "PME et indépendants ayant des tâches répétitives ou chronophages"
        needs = @(
            "gagner du temps",
            "automatiser les tâches",
            "réduire les erreurs",
            "mieux organiser les opérations"
        )
        buying_trigger = "Besoin concret d'optimisation et retour sur investissement compréhensible"
    }

    value_proposition = @{
        headline = "Automatiser les tâches répétitives pour libérer du temps et améliorer la productivité."
        proof = "Mettre en avant des cas d'usage concrets et des gains mesurables."
        differentiation = "Accompagnement de bout en bout : diagnostic, automatisation, agents IA et optimisation."
    }

    acquisition_channels = @(
        "LinkedIn",
        "Instagram",
        "Facebook",
        "Email outbound",
        "Prospection directe",
        "SEO",
        "Partenariats"
    )

    content_strategy = @{
        pillars = @(
            "Avant / après d'une tâche automatisée",
            "Démonstrations d'agents IA",
            "Cas clients et résultats",
            "Conseils productivité / IA",
            "Coulisses et expertise BK Entreprise"
        )
        cadence = "3 à 5 contenus par semaine"
    }

    conversion_strategy = @{
        offer = "Diagnostic IA / audit d'optimisation"
        call_to_action = "Réserver un diagnostic"
        funnel = @(
            "Contenu ou prospection",
            "Prise de contact",
            "Qualification",
            "Diagnostic",
            "Proposition",
            "Suivi"
        )
    }

    first_7_days = @(
        "Définir l'offre et son prix cible",
        "Créer la page de présentation",
        "Créer 3 contenus de démonstration",
        "Préparer un script de prospection",
        "Créer une liste de prospects qualifiés",
        "Lancer les premiers contacts",
        "Mesurer réponses, rendez-vous et conversions"
    )

    kpis = @(
        "Nombre de prospects contactés",
        "Taux de réponse",
        "Nombre de rendez-vous",
        "Taux de conversion",
        "Coût d'acquisition",
        "Chiffre d'affaires généré"
    )
}

$answer = @"
STRATEGIE MARKETING MAYA

TYPE : $objectiveType

POSITIONNEMENT
$($strategy.positioning.principle)

CIBLE
$($strategy.target.primary)

PROPOSITION DE VALEUR
$($strategy.value_proposition.headline)

CANAUX PRIORITAIRES
$($strategy.acquisition_channels -join ", ")

STRATEGIE DE CONTENU
$($strategy.content_strategy.pillars -join " | ")

CONVERSION
$($strategy.conversion_strategy.offer)
CTA : $($strategy.conversion_strategy.call_to_action)

PLAN 7 JOURS
$($strategy.first_7_days -join " | ")

KPI
$($strategy.kpis -join ", ")
"@

$output = [ordered]@{
    status = "SUCCESS"
    worker = "MAYA"
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    request = $Request
    objective_type = $objectiveType
    mode = "LOCAL_INTELLIGENCE"
    provider = "NONE"
    model = "NONE"
    fallback = $false
    context_loaded = $true
    memory_loaded = $true
    strategy = $strategy
    answer = $answer
    recommended_workers = @(
        "MAYA",
        "ALEX",
        "EMMA",
        "LEA",
        "LUCAS"
    )
    next_action = "Transformer la stratégie en offre, campagne, contenus et plan d'acquisition."
    security_status = "VALID"
    financial_actions = $false
    external_actions = $false
    generated_at = (Get-Date).ToString("o")
}

New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null

$outputPath = Join-Path $runtimePath "MAYA-$TaskId.json"

$output |
    ConvertTo-Json -Depth 30 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " MAYA INTELLIGENCE RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "STATUS       : SUCCESS"
Write-Host "MODE         : LOCAL_INTELLIGENCE"
Write-Host "OBJECTIVE    : $objectiveType"
Write-Host "SECURITY     : VALID"
Write-Host "FINANCE      : BLOCKED"
Write-Host "EXTERNAL     : BLOCKED"
Write-Host ""
Write-Host "POSITIONING  : READY"
Write-Host "TARGET       : READY"
Write-Host "VALUE PROP   : READY"
Write-Host "CHANNELS     : READY"
Write-Host "CONTENT      : READY"
Write-Host "CONVERSION   : READY"
Write-Host "7-DAY PLAN   : READY"
Write-Host "KPI          : READY"
Write-Host ""
Write-Host "OUTPUT : $outputPath"
Write-Host ""
Write-Host "MAYA INTELLIGENCE : READY"