# BK AI WORKERS
# GENERIC SKILL CONTRACT BUILDER

param()

$ErrorActionPreference = "Stop"

$skillsDir = $PSScriptRoot
$contractsDir = Join-Path $skillsDir "contracts"
$registryPath = Join-Path $skillsDir "SKILLS-REGISTRY.json"
$schemaPath = Join-Path $skillsDir "SKILL-CONTRACT-SCHEMA.json"

# -Encoding UTF8 est explicite : sans lui, Get-Content devine l'encodage et lit
# ce fichier UTF-8 sans BOM comme de l'ANSI, corrompant tous les caracteres accentues.
$registry = Get-Content -LiteralPath $registryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$schema = Get-Content -LiteralPath $schemaPath -Raw -Encoding UTF8 | ConvertFrom-Json

$workerName = [string]$registry.worker

$properties = @($registry.skills.PSObject.Properties)

$created = 0
$errors = 0

foreach ($property in $properties) {

    $skillId = $property.Name
    $skillConfig = $property.Value

    $contract = [ordered]@{
        skill_id = $skillId
        worker = $workerName
        category = [string]$skillConfig.category

        mission = [ordered]@{
            objective = [string]$skillConfig.description
            success_condition = "Livrable exploitable produit selon le contexte client et projet."
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
            "status"
        )

        tools = @(
            "AI_GATEWAY",
            "PROVIDER_ENGINE",
            "MEMORY_ENGINE",
            "ORCHESTRATOR"
        )

        memory = [ordered]@{
            global = $true
            client = $true
            project = $true
            worker = $true
            task = $true
            execution = $true
            raw_secret_access = $false
        }

        permissions = [ordered]@{
            read = $true
            write = $true
            create = $true
            modify = $true
            send = $true
            financial_actions = $false
            external_actions = $false
        }

        dependencies = @(
            "CONTEXT_VALIDATION",
            "CLIENT_ISOLATION",
            "PROJECT_ISOLATION",
            "WORKER_ISOLATION"
        )

        collaborators = @(
            "NOAH",
            "SAM",
            "ALEX"
        )

        kpis = @(
            "deliverable_quality",
            "task_completion",
            "execution_time",
            "business_relevance"
        )

        security = [ordered]@{
            status = "VALID"
            financial_actions = $false
            external_actions = $false
            secret_exposure = $false
            client_isolation = $true
            project_isolation = $true
            worker_isolation = $true
        }

        escalation = [ordered]@{
            human_required_for = @(
                "financial_transaction",
                "credential_exposure",
                "permission_escalation",
                "unsafe_external_action"
            )
            default_status = "NEEDS_HUMAN"
        }

        error_handling = [ordered]@{
            states = @(
                "SUCCESS",
                "PARTIAL_SUCCESS",
                "BLOCKED",
                "NEEDS_HUMAN",
                "ERROR"
            )
            no_false_success = $true
        }

        lifecycle = [ordered]@{
            enabled = $true
            version = "1.0.0"
            generated_by = "GENERIC-SKILL-CONTRACT-BUILDER"
        }
    }

    try {
        $path = Join-Path $contractsDir "$skillId.json"

        $contract |
            ConvertTo-Json -Depth 30 |
            Set-Content -LiteralPath $path -Encoding UTF8

        $created++
    }
    catch {
        $errors++
    }
}

Write-Host "WORKER          : $workerName"
Write-Host "SKILLS          : $($properties.Count)"
Write-Host "CONTRACTS       : $created"
Write-Host "ERRORS          : $errors"

if ($errors -gt 0) {
    exit 1
}

Write-Host "STATUS          : SUCCESS"
