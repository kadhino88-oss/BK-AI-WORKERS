# BK AI WORKERS
# MAYA SKILL CONTRACT BUILDER
# PHASE 7H-2

$ErrorActionPreference = "Stop"

$projectRoot = "C:\Users\FEUCOM\BK-AI-WORKERS"
$skillsDir = Join-Path $projectRoot "workers\maya\skills"
$registryPath = Join-Path $skillsDir "SKILLS-REGISTRY.json"
$contractsDir = Join-Path $skillsDir "contracts"

Write-Host ""
Write-Host "============================================"
Write-Host " BK AI WORKERS"
Write-Host " MAYA SKILL CONTRACT BUILDER"
Write-Host " PHASE 7H-2"
Write-Host "============================================"
Write-Host ""

if (!(Test-Path -LiteralPath $registryPath)) {
    Write-Host "SKILLS REGISTRY : NOT FOUND"
    exit 1
}

if (!(Test-Path -LiteralPath "$skillsDir\SKILL-CONTRACT-SCHEMA.json")) {
    Write-Host "CONTRACT SCHEMA : NOT FOUND"
    exit 1
}

try {
    $registry = Get-Content -LiteralPath $registryPath -Raw | ConvertFrom-Json
    $schema = Get-Content -LiteralPath "$skillsDir\SKILL-CONTRACT-SCHEMA.json" -Raw | ConvertFrom-Json
}
catch {
    Write-Host "CONFIGURATION JSON : INVALID"
    exit 1
}

Write-Host "REGISTRY : VALID"
Write-Host "SCHEMA   : VALID"

New-Item -ItemType Directory -Force -Path $contractsDir | Out-Null

$properties = @($registry.skills.PSObject.Properties)

if ($properties.Count -eq 0) {
    Write-Host "SKILLS : NONE"
    exit 1
}

$created = 0

foreach ($property in $properties) {

    $skillId = $property.Name
    $skillConfig = $property.Value
    $category = [string]$skillConfig.category
    $description = [string]$skillConfig.description

    $contract = [ordered]@{
        skill_id = $skillId
        worker = "MAYA"
        category = $category

        mission = @{
            objective = $description
            success_condition = "Livrable exploitable produit conformément au contexte client et projet."
        }

        inputs = @(
            "client_id",
            "project_id",
            "task_id",
            "objective",
            "validated_context",
            "validated_memory"
        )

        outputs = @(
            "deliverable",
            "recommendations",
            "next_action",
            "kpi_targets",
            "status"
        )

        tools = @(
            "AI_GATEWAY",
            "PROVIDER_ENGINE",
            "MEMORY_ENGINE",
            "ORCHESTRATOR"
        )

        memory = @{
            global = $true
            client = $true
            project = $true
            worker = $true
            task = $true
            execution = $true
            raw_secret_access = $false
        }

        permissions = @{
            read = $true
            write = $true
            send = $true
            create = $true
            modify = $true
            financial_actions = $false
            external_actions = $false
        }

        dependencies = @(
            "CONTEXT_VALIDATION",
            "CLIENT_ISOLATION",
            "PROJECT_ISOLATION"
        )

        collaborators = @(
            "ALEX",
            "EMMA",
            "LEA",
            "LUCAS",
            "NOAH"
        )

        kpis = @(
            "deliverable_quality",
            "execution_time",
            "task_completion",
            "business_relevance"
        )

        security = @{
            status = "VALID"
            financial_actions = $false
            external_actions = $false
            secret_exposure = $false
            client_isolation = $true
            project_isolation = $true
            worker_isolation = $true
        }

        escalation = @{
            human_required_for = @(
                "financial_transaction",
                "credential_exposure",
                "permission_escalation",
                "unsafe_external_action"
            )
            default_status = "NEEDS_HUMAN"
        }

        error_handling = @{
            states = @(
                "SUCCESS",
                "PARTIAL_SUCCESS",
                "BLOCKED",
                "NEEDS_HUMAN",
                "ERROR"
            )
            no_false_success = $true
        }

        lifecycle = @{
            enabled = $true
            version = "1.0.0"
            generated_by = "MAYA-SKILL-CONTRACT-BUILDER"
        }
    }

    $safeName = $skillId.ToUpperInvariant()
    $path = Join-Path $contractsDir "$safeName.json"

    $contract |
        ConvertTo-Json -Depth 30 |
        Set-Content -LiteralPath $path -Encoding UTF8

    $created++
}

Write-Host ""
Write-Host "============================================"
Write-Host " CONTRACT GENERATION RESULT"
Write-Host "============================================"
Write-Host ""

Write-Host "WORKER          : MAYA"
Write-Host "SKILLS IN REG   : $($properties.Count)"
Write-Host "CONTRACTS CREATED: $created"
Write-Host "SECURITY        : VALID"
Write-Host "FINANCE         : BLOCKED"
Write-Host "EXTERNAL        : BLOCKED"
Write-Host ""

$files = @(Get-ChildItem -LiteralPath $contractsDir -Filter "*.json" -File)

$invalid = 0

foreach ($file in $files) {

    try {
        $contract = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json

        foreach ($field in $schema.required_fields) {
            $value = $contract.PSObject.Properties[$field]

            if ($null -eq $value) {
                $invalid++
                Write-Host "INVALID : $($file.Name) -> $field"
            }
        }

        if ($contract.worker -ne "MAYA") {
            $invalid++
            Write-Host "INVALID : $($file.Name) -> worker"
        }

        if ($contract.security.financial_actions -ne $false) {
            $invalid++
            Write-Host "INVALID : $($file.Name) -> financial_actions"
        }

        if ($contract.security.external_actions -ne $false) {
            $invalid++
            Write-Host "INVALID : $($file.Name) -> external_actions"
        }

        if ($contract.security.secret_exposure -ne $false) {
            $invalid++
            Write-Host "INVALID : $($file.Name) -> secret_exposure"
        }

    }
    catch {
        $invalid++
        Write-Host "INVALID JSON : $($file.Name)"
    }
}

Write-Host ""
Write-Host "VALIDATION"
Write-Host "----------"
Write-Host "FILES CHECKED : $($files.Count)"
Write-Host "ERRORS        : $invalid"
Write-Host ""

if ($invalid -gt 0) {
    Write-Host "STATUS : ERROR"
    exit 1
}

Write-Host "STATUS : SUCCESS"
Write-Host "CONTRACTS : VALID"
Write-Host ""
Write-Host "MAYA SKILL CONTRACT FRAMEWORK : READY"