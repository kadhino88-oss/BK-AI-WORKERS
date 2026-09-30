# BK AI WORKERS
# GENERIC WORKER SKILL RUNTIME
# PHASE 7H-6

param(
    [Parameter(Mandatory=$true)]
    [ValidateScript({
        $RegistryPath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\worker-runtime\WORKER-REGISTRY.json"
        $Registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
        $ValidIds = $Registry.workers.PSObject.Properties.Name | ForEach-Object { $_.ToUpperInvariant() }
        if ($ValidIds -contains $_.ToUpperInvariant()) { return $true }
        throw "WorkerId '$_' absent de WORKER-REGISTRY.json (valeurs valides : $($ValidIds -join ', '))"
    })]
    [string]$WorkerId,

    [Parameter(Mandatory=$true)]
    [string]$Request,

    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$false)]
    [string]$ContextPath = "",

    [Parameter(Mandatory=$false)]
    [string]$MemoryPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$workerDir = Join-Path $projectRoot "workers\$($WorkerId.ToLower())"
$skillsDir = Join-Path $workerDir "skills"
$registryPath = Join-Path $skillsDir "SKILLS-REGISTRY.json"
$contractsDir = Join-Path $skillsDir "contracts"
$runtimeDir = Join-Path $projectRoot "memory\runtime"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " GENERIC WORKER SKILL RUNTIME"
Write-Host " PHASE 7H-6"
Write-Host "============================================"
Write-Host ""

Write-Host "WORKER  : $WorkerId"
Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "TASK    : $TaskId"
Write-Host ""

if ([string]::IsNullOrWhiteSpace($Request)) {
    Write-Host "REQUEST : INVALID"
    exit 1
}

if (!(Test-Path -LiteralPath $workerDir)) {
    Write-Host "WORKER DIRECTORY : NOT FOUND"
    exit 1
}

if (!(Test-Path -LiteralPath $registryPath)) {
    Write-Host "SKILL REGISTRY : NOT FOUND"
    exit 1
}

if (!(Test-Path -LiteralPath $contractsDir)) {
    Write-Host "CONTRACTS DIRECTORY : NOT FOUND"
    exit 1
}

try {
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "SKILL REGISTRY : INVALID JSON"
    exit 1
}

if ($registry.worker -ne $WorkerId) {
    Write-Host "WORKER REGISTRY IDENTITY : INVALID"
    exit 1
}

Write-Host "REGISTRY : VALID"

if (![string]::IsNullOrWhiteSpace($ContextPath)) {

    if (!(Test-Path -LiteralPath $ContextPath)) {
        Write-Host "CONTEXT : NOT FOUND"
        exit 1
    }

    try {
        $context = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "CONTEXT : INVALID"
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

    Write-Host "CONTEXT : VALID"
}

if (![string]::IsNullOrWhiteSpace($MemoryPath)) {

    if (!(Test-Path -LiteralPath $MemoryPath)) {
        Write-Host "MEMORY : NOT FOUND"
        exit 1
    }

    try {
        $memory = Get-Content -LiteralPath $MemoryPath -Raw | ConvertFrom-Json
    }
    catch {
        Write-Host "MEMORY : INVALID"
        exit 1
    }

    Write-Host "MEMORY : VALID"
}

function Select-Skill {
    param(
        [string]$Worker,
        [string]$Text
    )

    $t = $Text.ToLowerInvariant()

    switch ($Worker) {

        "MAYA" {
            if ($t -match "lancement|lancer|nouveau produit|nouveau service") { return "PRODUCT_LAUNCH" }
            if ($t -match "prospect|acquisition|lead") { return "CUSTOMER_ACQUISITION" }
            if ($t -match "contenu|éditorial|réseaux sociaux") { return "CONTENT_STRATEGY" }
            if ($t -match "publicité|ads|campagne payante") { return "PAID_MARKETING" }
            if ($t -match "seo|référencement") { return "SEO_STRATEGY" }
            if ($t -match "crm|automatisation marketing") { return "CRM_STRATEGY" }
            return "MARKETING_STRATEGY"
        }

        "ALEX" {
            if ($t -match "prospect|prospection") { return "PROSPECTING_STRATEGY" }
            if ($t -match "lead|prospects|génération") { return "LEAD_GENERATION" }
            if ($t -match "crm") { return "CRM_MANAGEMENT" }
            if ($t -match "relance|relancer") { return "FOLLOW_UP_STRATEGY" }
            if ($t -match "email|cold email") { return "COLD_EMAIL" }
            return "PROSPECTING_STRATEGY"
        }

        "LEA" {
            if ($t -match "logo") { return "LOGO_DESIGN" }
            if ($t -match "identité|charte") { return "VISUAL_IDENTITY" }
            if ($t -match "branding|marque") { return "BRAND_STRATEGY" }
            if ($t -match "ux|ui|interface") { return "UI_DESIGN" }
            if ($t -match "campagne|publicité visuelle") { return "CREATIVE_CAMPAIGN" }
            return "CREATIVE_DIRECTION"
        }

        "NOAH" {
            if ($t -match "email|courriel") { return "EMAIL_MANAGEMENT" }
            if ($t -match "agenda|rendez-vous") { return "CALENDAR_MANAGEMENT" }
            if ($t -match "réunion|compte rendu") { return "MEETING_SUMMARY" }
            if ($t -match "document|rapport") { return "DOCUMENT_DRAFTING" }
            if ($t -match "planning|priorité|tâche") { return "TASK_MANAGEMENT" }
            return "EXECUTIVE_BRIEFING"
        }

        "LUCAS" {
            if ($t -match "wordpress") { return "WORDPRESS_DEVELOPMENT" }
            if ($t -match "webflow") { return "WEBFLOW_DEVELOPMENT" }
            if ($t -match "seo|référencement") { return "TECHNICAL_SEO" }
            if ($t -match "landing page") { return "LANDING_PAGE_BUILD" }
            if ($t -match "performance|vitesse") { return "PERFORMANCE_AUDIT" }
            if ($t -match "analytics|statistiques") { return "WEB_ANALYTICS" }
            return "WEB_ARCHITECTURE"
        }

        "EMMA" {
            if ($t -match "instagram") { return "INSTAGRAM" }
            if ($t -match "facebook") { return "FACEBOOK" }
            if ($t -match "linkedin") { return "LINKEDIN" }
            if ($t -match "tiktok") { return "TIKTOK" }
            if ($t -match "contenu|éditorial") { return "CONTENT_STRATEGY" }
            if ($t -match "community|communauté") { return "COMMUNITY_MANAGEMENT" }
            return "SOCIAL_MEDIA_STRATEGY"
        }

        "SAM" {
            if ($t -match "cyber|sécurité") { return "CYBERSECURITY_AUDIT" }
            if ($t -match "serveur|infrastructure") { return "SERVER_MANAGEMENT" }
            if ($t -match "réseau|network") { return "NETWORK_MONITORING" }
            if ($t -match "backup|sauvegarde") { return "BACKUP_STRATEGY" }
            if ($t -match "incident|attaque") { return "INCIDENT_DETECTION" }
            if ($t -match "vulnérabilité") { return "VULNERABILITY_SCANNING" }
            return "SECURITY_AUDIT"
        }
    }

    return $null
}

$selectedSkill = Select-Skill -Worker $WorkerId -Text $Request

if ([string]::IsNullOrWhiteSpace($selectedSkill)) {
    Write-Host "SKILL ROUTING : FAILED"
    exit 1
}

Write-Host ""
Write-Host "============================================"
Write-Host " SKILL ROUTING"
Write-Host "============================================"
Write-Host ""

Write-Host "SELECTED SKILL : $selectedSkill"

$contractPath = Join-Path $contractsDir "$selectedSkill.json"

if (!(Test-Path -LiteralPath $contractPath)) {
    Write-Host "SKILL CONTRACT : NOT FOUND"
    Write-Host "EXPECTED : $contractPath"
    exit 1
}

try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "SKILL CONTRACT : INVALID JSON"
    exit 1
}

if ($contract.skill_id -ne $selectedSkill) {
    Write-Host "SKILL CONTRACT IDENTITY : INVALID"
    exit 1
}

if ($contract.worker -ne $WorkerId) {
    Write-Host "SKILL WORKER IDENTITY : INVALID"
    exit 1
}

Write-Host "SKILL CONTRACT : VALID"

if ($contract.security.financial_actions -ne $false) {
    Write-Host "FINANCE : ERROR"
    exit 1
}

if ($contract.security.external_actions -ne $false) {
    Write-Host "EXTERNAL : ERROR"
    exit 1
}

if ($contract.security.secret_exposure -ne $false) {
    Write-Host "SECRET EXPOSURE : ERROR"
    exit 1
}

if ($contract.security.client_isolation -ne $true -or
    $contract.security.project_isolation -ne $true -or
    $contract.security.worker_isolation -ne $true) {
    Write-Host "ISOLATION : ERROR"
    exit 1
}

Write-Host "SECURITY : VALID"
Write-Host "ISOLATION : VALID"
Write-Host "FINANCE : BLOCKED"
Write-Host "EXTERNAL : BLOCKED"

$deliverable = [ordered]@{
    worker = $WorkerId
    skill = $selectedSkill
    category = $contract.category
    request = $Request
    mission = $contract.mission
    required_inputs = $contract.inputs
    expected_outputs = $contract.outputs
    tools = $contract.tools
    collaborators = $contract.collaborators
    kpis = $contract.kpis
    next_action = "Exécuter le livrable avec les outils autorisés."
}

$result = [ordered]@{
    status = "SUCCESS"
    worker = $WorkerId
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    selected_skill = $selectedSkill
    contract_path = $contractPath
    contract_valid = $true
    mode = "GENERIC_SKILL_RUNTIME_LOCAL"
    deliverable = $deliverable
    context_loaded = (![string]::IsNullOrWhiteSpace($ContextPath))
    memory_loaded = (![string]::IsNullOrWhiteSpace($MemoryPath))
    security_status = "VALID"
    financial_actions = $false
    external_actions = $false
    generated_at = (Get-Date).ToString("o")
}

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

$outputPath = Join-Path `
    $runtimeDir `
    "GENERIC-SKILL-$WorkerId-$TaskId.json"

$result |
    ConvertTo-Json -Depth 40 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " GENERIC SKILL RUNTIME RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "STATUS        : SUCCESS"
Write-Host "WORKER        : $WorkerId"
Write-Host "SKILL         : $selectedSkill"
Write-Host "CONTRACT      : VALID"
Write-Host "SECURITY      : VALID"
Write-Host "ISOLATION     : VALID"
Write-Host "FINANCE       : BLOCKED"
Write-Host "EXTERNAL      : BLOCKED"
Write-Host "MODE          : GENERIC_SKILL_RUNTIME_LOCAL"
Write-Host ""

Write-Host "DELIVERABLE   : PREPARED"
Write-Host "OUTPUT        : $outputPath"
Write-Host ""
Write-Host "GENERIC WORKER SKILL RUNTIME : READY"