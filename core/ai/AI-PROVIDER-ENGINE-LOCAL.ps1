# BK AI WORKERS
# AI PROVIDER ENGINE
# PHASE 7G-2
# RESILIENT PROVIDER + LOCAL FALLBACK

param(
    [Parameter(Mandatory=$true)]
    [string]$ClientId,

    [Parameter(Mandatory=$true)]
    [string]$ProjectId,

    [Parameter(Mandatory=$true)]
    # ValidateSet fige remplace le 2026-09-14 (bloquait SEOYA et tout futur
    # Worker) par une lecture dynamique du registre central : ajouter un
    # Worker a core\runtime\worker-runtime\WORKER-REGISTRY.json suffit
    # desormais a le rendre accepte ici, sans toucher ce fichier.
    [ValidateScript({
        $RegistryPath = (Join-Path $(if ($env:BK_ROOT) { $env:BK_ROOT } else { "C:/Users/FEUCOM/BK-AI-WORKERS" }) "core/runtime/worker-runtime/WORKER-REGISTRY.json")
        $Registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json
        $ValidIds = $Registry.workers.PSObject.Properties.Name | ForEach-Object { $_.ToUpperInvariant() }
        if ($ValidIds -contains $_.ToUpperInvariant()) { return $true }
        throw "WorkerId '$_' absent de WORKER-REGISTRY.json (valeurs valides : $($ValidIds -join ', '))"
    })]
    [string]$WorkerId,

    [Parameter(Mandatory=$true)]
    [string]$TaskId,

    [Parameter(Mandatory=$true)]
    [string]$Objective,

    [Parameter(Mandatory=$false)]
    [ValidateSet("NONE","OPENAI","ANTHROPIC")]
    [string]$Provider = "NONE",

    [Parameter(Mandatory=$false)]
    [string]$Model = "NONE",

    [Parameter(Mandatory=$false)]
    [string]$ContextPath = "",

    [Parameter(Mandatory=$false)]
    [string]$MemoryPath = ""
)

$ErrorActionPreference = "Stop"

$aiRoot = $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent $aiRoot)
$configPath = Join-Path $aiRoot "AI-PROVIDERS.json"
$runtimePath = Join-Path $projectRoot "memory/runtime"
$credentialLoader = Join-Path $aiRoot "SECURE-CREDENTIAL-LOADER.ps1"
$openaiAdapter = Join-Path $aiRoot "adapters/OPENAI-ADAPTER.ps1"
$anthropicAdapter = Join-Path $aiRoot "adapters/ANTHROPIC-ADAPTER.ps1"
# Choix du moteur par mission (2026-10-25) : quand le serveur a pose un plan de moteurs (BK_ENGINE_PLAN, voir dashboard/provider_router.py), la mission passe par
# l'executeur de chaine (Claude, moteur local, hote suisse ou cle du client, repli etiquete). Sans plan : l'adaptateur de Claude, exactement comme avant.
$engineChain = Join-Path $aiRoot "Invoke-EngineChain.ps1"
$useEngineChain = ((-not [string]::IsNullOrWhiteSpace($env:BK_ENGINE_PLAN)) -and (Test-Path -LiteralPath $engineChain -PathType Leaf))

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " AI PROVIDER ENGINE"
Write-Host " PHASE 7G-2"
Write-Host " RESILIENT PROVIDER + LOCAL FALLBACK"
Write-Host "============================================"
Write-Host ""

Write-Host "CLIENT   : $ClientId"
Write-Host "PROJECT  : $ProjectId"
Write-Host "WORKER   : $WorkerId"
Write-Host "TASK     : $TaskId"
Write-Host "PROVIDER : $Provider"
Write-Host "MODEL    : $Model"
Write-Host ""

if (!(Test-Path -LiteralPath $configPath)) {
    Write-Host "CONFIG : ERROR"
    exit 1
}

try {
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
}
catch {
    Write-Host "CONFIG JSON : INVALID"
    exit 1
}

Write-Host "CONFIG : VALID"

if ([string]::IsNullOrWhiteSpace($ClientId) -or
    [string]::IsNullOrWhiteSpace($ProjectId) -or
    [string]::IsNullOrWhiteSpace($TaskId) -or
    [string]::IsNullOrWhiteSpace($Objective)) {
    Write-Host "IDENTITY / OBJECTIVE : INVALID"
    exit 1
}

if ($config.security.client_isolation -ne $true) {
    Write-Host "CLIENT ISOLATION : ERROR"
    exit 1
}

if ($config.security.project_isolation -ne $true) {
    Write-Host "PROJECT ISOLATION : ERROR"
    exit 1
}

if ($config.security.worker_isolation -ne $true) {
    Write-Host "WORKER ISOLATION : ERROR"
    exit 1
}

if ($config.security.secret_exposure -ne $false) {
    Write-Host "SECRET EXPOSURE : ERROR"
    exit 1
}

if ($config.security.financial_actions -ne $false) {
    Write-Host "FINANCE : ERROR"
    exit 1
}

if ($config.security.external_actions -ne $false) {
    Write-Host "EXTERNAL : ERROR"
    exit 1
}

Write-Host "IDENTITY   : VALID"
Write-Host "ISOLATION  : VALID"
Write-Host "SECURITY   : VALID"
Write-Host "FINANCE    : BLOCKED"
Write-Host "EXTERNAL   : BLOCKED"

$memoryLoaded = $false
$contextLoaded = $false

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

    $contextLoaded = $true
    Write-Host "CONTEXT : LOADED"
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

    $memoryLoaded = $true
    Write-Host "MEMORY : LOADED"
}

Write-Host ""
Write-Host "============================================"
Write-Host " PROVIDER RESOLUTION"
Write-Host "============================================"
Write-Host ""

$effectiveProvider = $Provider.ToUpper()
$effectiveModel = $Model

if ($effectiveProvider -eq "NONE") {

    Write-Host "SELECTED : LOCAL"
    Write-Host "MODEL    : NONE"
    Write-Host "MODE     : LOCAL"

    $result = [ordered]@{
        status = "SUCCESS"
        mode = "LOCAL"
        provider = "NONE"
        model = "NONE"
        worker = $WorkerId
        task_id = $TaskId
        client_id = $ClientId
        project_id = $ProjectId
        answer = "Réponse locale de secours disponible."
        recommendations = @()
        next_action = "Traiter la demande avec l'intelligence locale du Worker."
        security_status = "VALID"
        financial_actions = $false
        external_actions = $false
        fallback = $false
        fallback_reason = ""
        context_loaded = $contextLoaded
        memory_loaded = $memoryLoaded
        generated_at = (Get-Date).ToString("o")
    }
}
else {

    Write-Host "REQUESTED PROVIDER : $effectiveProvider"
    Write-Host "MODEL              : $effectiveModel"

    $providerAvailable = $false
    $providerAnswer = ""
    $providerMode = ""
    $providerUsage = $null
    $providerFiles = @()
    $providerCostCapped = $false   # mission arretee a son plafond de cout (ANTHROPIC-ADAPTER.ps1, Mission-Cost.ps1)
    $providerEngine = $null        # moteur qui a reellement repondu (executeur de chaine) : { provider, model, local, failedOver, label... }
    $providerRealModel = $null
    $providerUserMessage = ""
    $providerResult = $null
    $providerError = ""

    if ($effectiveProvider -eq "OPENAI") {

        if (!(Test-Path -LiteralPath $openaiAdapter)) {
            $providerError = "OPENAI_ADAPTER_MISSING"
        }
        elseif ($config.providers.openai.enabled -ne $true) {
            $providerError = "OPENAI_DISABLED_IN_CONFIG"
        }
        elseif ($config.llm_enabled -ne $true) {
            $providerError = "LLM_GLOBAL_DISABLED"
        }
        elseif ($config.development.api_calls_enabled -ne $true) {
            $providerError = "API_CALLS_DISABLED"
        }
        else {
            Write-Host "OPENAI : CONFIGURED"
            Write-Host "OPENAI : READY FOR LIVE PATH"

            try {
                $providerResultRaw = & $openaiAdapter `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -WorkerId $WorkerId `
                    -TaskId $TaskId `
                    -Objective $Objective `
                    -Model $effectiveModel 2>&1

                if ($LASTEXITCODE -eq 0) {
                    # On lit la vraie reponse renvoyee par l'adapter (JSON
                    # sur la derniere ligne de sortie) plutot qu'un texte
                    # fixe : avant le 2026-09-14, cette valeur etait codee
                    # en dur ici et ignorait completement ce que l'adapter
                    # avait reellement obtenu du fournisseur.
                    # Sortie complete de l'adapter (JSON eventuellement sur plusieurs lignes).
                    $ParsedProvider = ($providerResultRaw | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue

                    if ($null -ne $ParsedProvider -and -not [string]::IsNullOrWhiteSpace([string]$ParsedProvider.answer)) {
                        $providerAvailable = $true
                        $providerMode = "OPENAI"
                        $providerAnswer = [string]$ParsedProvider.answer
                        $providerUsage = $ParsedProvider.usage
                    }
                    else {
                        $providerError = "OPENAI_EMPTY_RESPONSE"
                    }
                }
                else {
                    $providerError = "OPENAI_EXIT_CODE_$LASTEXITCODE"
                }
            }
            catch {
                $providerError = "OPENAI_REQUEST_ERROR"
            }
        }
    }
    elseif ($effectiveProvider -eq "ANTHROPIC") {

        if (!(Test-Path -LiteralPath $anthropicAdapter)) {
            $providerError = "ANTHROPIC_ADAPTER_MISSING"
        }
        elseif ($config.providers.anthropic.enabled -ne $true) {
            $providerError = "ANTHROPIC_DISABLED_IN_CONFIG"
        }
        elseif ($config.llm_enabled -ne $true) {
            $providerError = "LLM_GLOBAL_DISABLED"
        }
        elseif ($config.development.api_calls_enabled -ne $true) {
            $providerError = "API_CALLS_DISABLED"
        }
        else {
            Write-Host "ANTHROPIC : CONFIGURED"
            Write-Host "ANTHROPIC : READY FOR LIVE PATH"

            try {
                $providerResult = & $(if ($useEngineChain) { $engineChain } else { $anthropicAdapter }) `
                    -ClientId $ClientId `
                    -ProjectId $ProjectId `
                    -WorkerId $WorkerId `
                    -TaskId $TaskId `
                    -Objective $Objective `
                    -Model $effectiveModel 2>&1

                if ($LASTEXITCODE -eq 0) {
                    $ParsedAnthropic = ($providerResult | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue
                    if ($null -ne $ParsedAnthropic -and -not [string]::IsNullOrWhiteSpace([string]$ParsedAnthropic.answer)) {
                        $providerAvailable = $true
                        $providerMode = "ANTHROPIC"
                        $providerAnswer = [string]$ParsedAnthropic.answer
                        $providerUsage = $ParsedAnthropic.usage
                        $providerFiles = if ($ParsedAnthropic.files) { $ParsedAnthropic.files } else { @() }
                        $CostCappedProp = $ParsedAnthropic.PSObject.Properties["cost_capped"]
                        $providerCostCapped = [bool]($CostCappedProp -and $CostCappedProp.Value)
                        if ($useEngineChain) {
                            $providerEngine = $ParsedAnthropic.engine
                            $providerRealModel = [string]$ParsedAnthropic.model
                        }
                    }
                    else {
                        $providerError = "ANTHROPIC_EMPTY_RESPONSE"
                    }
                }
                else {
                    $providerError = "ANTHROPIC_EXIT_CODE_$LASTEXITCODE"
                    if ($useEngineChain) {
                        # Aucun moteur de la chaine n'a repondu : on garde la raison (jamais de secret) et les essais pour l'afficher honnetement.
                        $ParsedChainError = ($providerResult | Out-String) | ConvertFrom-Json -ErrorAction SilentlyContinue
                        if ($null -ne $ParsedChainError) {
                            if ($ParsedChainError.error) { $providerError = ([string]$ParsedChainError.error) }
                            $providerEngine = $ParsedChainError.engine
                            $providerUserMessage = [string]$ParsedChainError.user_message
                        }
                    }
                }
            }
            catch {
                $providerError = "ANTHROPIC_REQUEST_ERROR"
            }
        }
    }

    if ($providerAvailable) {

        # Avec un plan de moteurs, le fournisseur et le modele sont CEUX QUI ONT REPONDU (jamais « ANTHROPIC » pour une reponse d'un modele local).
        $reportedProvider = $effectiveProvider
        $reportedModel = $effectiveModel
        if ($null -ne $providerEngine -and $providerEngine.provider) {
            $reportedProvider = ([string]$providerEngine.provider).ToUpperInvariant()
            if (-not [string]::IsNullOrWhiteSpace($providerRealModel)) { $reportedModel = $providerRealModel }
        }

        $result = [ordered]@{
            status = "SUCCESS"
            mode = "LLM"
            provider = $reportedProvider
            model = $reportedModel
            worker = $WorkerId
            task_id = $TaskId
            client_id = $ClientId
            project_id = $ProjectId
            answer = $providerAnswer
            usage = $providerUsage
            cost_capped = $providerCostCapped
            files = @($providerFiles)
            recommendations = @()
            next_action = "Utiliser la réponse du fournisseur dans le traitement du Worker."
            security_status = "VALID"
            financial_actions = $false
            external_actions = $false
            fallback = $false
            fallback_reason = ""
            context_loaded = $contextLoaded
            memory_loaded = $memoryLoaded
            generated_at = (Get-Date).ToString("o")
        }
    }
    else {

        Write-Host ""
        Write-Host "PROVIDER UNAVAILABLE"
        Write-Host "REASON : $providerError"
        Write-Host "FALLBACK : LOCAL"

        # Avec un plan de moteurs, aucun moteur n'a repondu : la reponse de secours n'est PAS celle d'un fournisseur (jamais etiquetee ANTHROPIC), elle dit
        # honnetement pourquoi et que la mission est gratuite (Degraded -> 0 credit, Get-BKMissionCredits).
        $fallbackProvider = $effectiveProvider
        $fallbackModel = $effectiveModel
        $fallbackAnswer = "Le fournisseur IA externe n'est pas disponible. Le traitement local reste disponible."
        if ($useEngineChain -and $effectiveProvider -eq "ANTHROPIC") {
            $fallbackProvider = "NONE"
            $fallbackModel = "NONE"
            if (-not [string]::IsNullOrWhiteSpace($providerUserMessage)) { $fallbackAnswer = $providerUserMessage }
            else { $fallbackAnswer = "Aucun moteur d'IA n'a pu répondre pour le moment. Votre mission n'a pas été traitée et ne consomme aucun crédit. Réessayez dans quelques minutes." }
        }

        $result = [ordered]@{
            status = "FALLBACK"
            mode = "LOCAL"
            provider = $fallbackProvider
            model = $fallbackModel
            worker = $WorkerId
            task_id = $TaskId
            client_id = $ClientId
            project_id = $ProjectId
            answer = $fallbackAnswer
            recommendations = @()
            next_action = "Continuer avec le moteur local du Worker ou réessayer lorsque le fournisseur sera disponible."
            security_status = "VALID"
            financial_actions = $false
            external_actions = $false
            fallback = $true
            fallback_reason = $providerError
            context_loaded = $contextLoaded
            memory_loaded = $memoryLoaded
            generated_at = (Get-Date).ToString("o")
        }
    }
}

# Moteur qui a reellement repondu (ou n'a pas pu) : present SEULEMENT quand un plan de moteurs est actif ; sans plan, le fichier est identique a celui d'avant.
if ($useEngineChain -and $effectiveProvider -eq "ANTHROPIC") { $result["engine"] = $providerEngine }

New-Item -ItemType Directory -Force -Path $runtimePath | Out-Null

$outputPath = Join-Path $runtimePath "PROVIDER-$TaskId.json"

$result |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $outputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " PROVIDER ENGINE RESULT"
Write-Host "============================================"
Write-Host ""
Write-Host "STATUS      : $($result.status)"
Write-Host "MODE        : $($result.mode)"
Write-Host "PROVIDER    : $($result.provider)"
Write-Host "MODEL       : $($result.model)"
Write-Host "FALLBACK    : $($result.fallback)"
Write-Host "SECURITY    : $($result.security_status)"
Write-Host "FINANCE     : BLOCKED"
Write-Host "EXTERNAL    : BLOCKED"
Write-Host ""
Write-Host "OUTPUT      : $outputPath"
Write-Host ""

if ($result.status -eq "SUCCESS") {
    Write-Host "PROVIDER ENGINE : SUCCESS"
    exit 0
}

if ($result.status -eq "FALLBACK") {
    Write-Host "PROVIDER ENGINE : FALLBACK LOCAL"
    exit 0
}

Write-Host "PROVIDER ENGINE : ERROR"
exit 1