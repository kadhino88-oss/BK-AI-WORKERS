# BK AI WORKERS
# MAYA - SKILL RUNTIME
# PHASE 7H-3
# SKILL ROUTING + CONTRACT EXECUTION

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

    [Parameter(Mandatory=$false)]
    [string]$ContextPath = "",

    [Parameter(Mandatory=$false)]
    [string]$MemoryPath = ""
)

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$skillsDir = Join-Path $projectRoot "workers\maya\skills"
$contractsDir = Join-Path $skillsDir "contracts"
$runtimeDir = Join-Path $projectRoot "memory\runtime"
$registryPath = Join-Path $skillsDir "SKILLS-REGISTRY.json"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MAYA - SKILL RUNTIME"
Write-Host " PHASE 7H-3"
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

if (!(Test-Path -LiteralPath $registryPath)) {
    Write-Host "SKILLS REGISTRY : NOT FOUND"
    exit 1
}

try {
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "SKILLS REGISTRY : INVALID"
    exit 1
}

Write-Host "SKILLS REGISTRY : VALID"

if (!(Test-Path -LiteralPath $contractsDir)) {
    Write-Host "CONTRACTS DIRECTORY : NOT FOUND"
    exit 1
}

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
else {
    Write-Host "CONTEXT : NOT PROVIDED"
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
else {
    Write-Host "MEMORY : NOT PROVIDED"
}

function Select-Skill {
    param([string]$Text)

    $t = $Text.ToLowerInvariant()

    $rules = @(
        @{ skill="PRODUCT_LAUNCH";       pattern="lancement|lancer|nouveau produit|nouveau service|launch|mise sur le marché|go.to.market" },
        @{ skill="GO_TO_MARKET";         pattern="go.to.market|mise sur le marché|entrée sur le marché" },
        @{ skill="BRAND_POSITIONING";    pattern="positionnement|différenciation|marque|branding" },
        @{ skill="COMPETITOR_ANALYSIS";  pattern="concurrent|concurrence|benchmark|analyse concurrentielle" },

        @{ skill="LEAD_GENERATION";     pattern="génération de leads|générer des leads|lead generation|leads" },
        @{ skill="CUSTOMER_ACQUISITION"; pattern="acquisition|acquérir des clients|nouveaux clients" },
        @{ skill="PROSPECT_SEGMENTATION"; pattern="segmenter|segmentation|segments de prospects" },
        @{ skill="FUNNEL_OPTIMIZATION"; pattern="funnel|tunnel de vente|tunnel de conversion" },
        @{ skill="LANDING_PAGE_STRATEGY"; pattern="landing page|page d'atterrissage|page de conversion" },
        @{ skill="PARTNERSHIP_MARKETING"; pattern="partenariat|partenaires|co-marketing" },

        @{ skill="CRM_STRATEGY";        pattern="crm|gestion de la relation client" },
        @{ skill="LEAD_SCORING";        pattern="lead scoring|scoring|qualification des leads" },
        @{ skill="LEAD_NURTURING";      pattern="nurturing|nourrir les leads|maturer les prospects" },
        @{ skill="MARKETING_AUTOMATION"; pattern="automatisation marketing|workflow marketing|automation marketing" },
        @{ skill="CUSTOMER_JOURNEY";    pattern="parcours client|customer journey|expérience client" },
        @{ skill="REACTIVATION";        pattern="réactivation|réactiver|clients inactifs" },

        @{ skill="EMAIL_MARKETING";     pattern="email marketing|e-mail marketing" },
        @{ skill="EMAIL_CAMPAIGN";      pattern="campagne email|campagne e-mail" },
        @{ skill="NEWSLETTER";          pattern="newsletter|infolettre" },
        @{ skill="LIFECYCLE_EMAIL";     pattern="cycle de vie|lifecycle email|email transactionnel marketing" },

        @{ skill="CONTENT_STRATEGY";    pattern="stratégie de contenu|contenu éditorial|ligne éditoriale" },
        @{ skill="SOCIAL_MEDIA_STRATEGY"; pattern="réseaux sociaux|social media|stratégie sociale" },
        @{ skill="SOCIAL_CAMPAIGN";     pattern="campagne sociale|campagne instagram|campagne facebook|campagne tiktok" },
        @{ skill="COMMUNITY_GROWTH";    pattern="communauté|community|engagement|croissance de communauté" },
        @{ skill="UGC_STRATEGY";        pattern="ugc|contenu utilisateur|user generated content" },
        @{ skill="INFLUENCER_MARKETING"; pattern="influenceur|influence|créateur de contenu" },

        @{ skill="SEO_STRATEGY";        pattern="seo|référencement naturel" },
        @{ skill="LOCAL_SEO";           pattern="seo local|référencement local|google business" },
        @{ skill="PAID_MARKETING";      pattern="publicité|ads|marketing payant|campagne payante" },
        @{ skill="GOOGLE_ADS";          pattern="google ads|adwords" },
        @{ skill="META_ADS";            pattern="meta ads|facebook ads|instagram ads" },
        @{ skill="RETARGETING";         pattern="retargeting|remarketing|reciblage" },
        @{ skill="AI_SEARCH_VISIBILITY"; pattern="recherche ia|visibilité ia|moteur ia|ai search|llm visibility" },

        @{ skill="MARKETING_ANALYTICS"; pattern="analytics|analyse marketing|données marketing" },
        @{ skill="CONVERSION_OPTIMIZATION"; pattern="conversion|taux de conversion|cro optimization|cro" },
        @{ skill="A_B_TESTING";         pattern="a/b test|test ab|expérimentation" },
        @{ skill="ATTRIBUTION";         pattern="attribution|source des conversions|multi-touch" },
        @{ skill="CAMPAIGN_REPORTING";  pattern="rapport de campagne|reporting marketing|bilan campagne" },
        @{ skill="GROWTH_OPTIMIZATION"; pattern="growth|croissance|growth hacking|optimisation croissance" },

        @{ skill="CUSTOMER_RETENTION";  pattern="rétention|retention|fidéliser|fidélisation" },
        @{ skill="CUSTOMER_LOYALTY";    pattern="fidélité|programme fidélité|loyauté client" },
        @{ skill="UPSELL_CROSS_SELL";   pattern="upsell|cross sell|cross-sell|vente additionnelle" },
        @{ skill="WIN_BACK";            pattern="win back|reconquête|reconquérir" },

        @{ skill="OFFER_STRATEGY";      pattern="offre|pack|formule|bundle|proposition commerciale" },
        @{ skill="PRICING_POSITIONING"; pattern="prix|pricing|tarification|positionnement prix" },
        @{ skill="SALES_ENABLEMENT";    pattern="sales enablement|support commercial|argumentaire commercial" },
        @{ skill="B2B_MARKETING";       pattern="b2b|business to business|entreprises" }
    )

    foreach ($rule in $rules) {
        if ($t -match $rule.pattern) {
            return $rule.skill
        }
    }

    return "MARKETING_STRATEGY"
}

$selectedSkill = Select-Skill -Text $Request

Write-Host ""
Write-Host "============================================"
Write-Host " SKILL ROUTING"
Write-Host "============================================"
Write-Host ""

Write-Host "SELECTED SKILL : $selectedSkill"

$contractPath = Join-Path $contractsDir "$selectedSkill.json"

if (!(Test-Path -LiteralPath $contractPath)) {
    Write-Host "SKILL CONTRACT : NOT FOUND"
    exit 1
}

try {
    $contract = Get-Content -LiteralPath $contractPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "SKILL CONTRACT : INVALID"
    exit 1
}

if ($contract.skill_id -ne $selectedSkill) {
    Write-Host "SKILL CONTRACT IDENTITY : INVALID"
    exit 1
}

if ($contract.worker -ne "MAYA") {
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

if ($contract.security.client_isolation -ne $true) {
    Write-Host "CLIENT ISOLATION : ERROR"
    exit 1
}

if ($contract.security.project_isolation -ne $true) {
    Write-Host "PROJECT ISOLATION : ERROR"
    exit 1
}

if ($contract.security.worker_isolation -ne $true) {
    Write-Host "WORKER ISOLATION : ERROR"
    exit 1
}

Write-Host "SKILL SECURITY : VALID"
Write-Host "FINANCE        : BLOCKED"
Write-Host "EXTERNAL       : BLOCKED"
Write-Host "SECRET         : BLOCKED"

$deliverable = [ordered]@{
    skill = $selectedSkill
    category = $contract.category
    objective = $contract.mission.objective
    request = $Request
    client = $ClientId
    project = $ProjectId
    task = $TaskId
    analysis = "Demande préparée par le Skill Runtime de MAYA conformément au contrat sélectionné."
    required_inputs = $contract.inputs
    required_outputs = $contract.outputs
    recommended_tools = $contract.tools
    collaborators = $contract.collaborators
    kpis = $contract.kpis
    next_action = "Exécuter le livrable métier avec les outils autorisés par le contrat."
}

$result = [ordered]@{
    status = "SUCCESS"
    worker = "MAYA"
    client_id = $ClientId
    project_id = $ProjectId
    task_id = $TaskId
    request = $Request
    selected_skill = $selectedSkill
    contract_path = $contractPath
    contract_version = $contract.lifecycle.version
    category = $contract.category
    mode = "SKILL_RUNTIME_LOCAL"
    deliverable = $deliverable
    security_status = "VALID"
    financial_actions = $false
    external_actions = $false
    context_loaded = (![string]::IsNullOrWhiteSpace($ContextPath))
    memory_loaded = (![string]::IsNullOrWhiteSpace($MemoryPath))
    generated_at = (Get-Date).ToString("o")
}

New-Item -ItemType Directory -Force -Path $runtimeDir | Out-Null

$outputPath = Join-Path $runtimeDir "SKILL-RUNTIME-MAYA-$TaskId.json"

$result |
    ConvertTo-Json -Depth 40 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " MAYA SKILL RUNTIME RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "STATUS        : SUCCESS"
Write-Host "WORKER        : MAYA"
Write-Host "SKILL         : $selectedSkill"
Write-Host "CATEGORY      : $($contract.category)"
Write-Host "CONTRACT      : VALID"
Write-Host "SECURITY      : VALID"
Write-Host "FINANCE       : BLOCKED"
Write-Host "EXTERNAL      : BLOCKED"
Write-Host "MODE          : SKILL_RUNTIME_LOCAL"
Write-Host ""
Write-Host "DELIVERABLE   : PREPARED"
Write-Host "OUTPUT        : $outputPath"
Write-Host ""
Write-Host "MAYA SKILL RUNTIME : READY"