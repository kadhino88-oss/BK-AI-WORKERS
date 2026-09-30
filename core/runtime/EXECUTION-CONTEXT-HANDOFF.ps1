param(
    [Parameter(Mandatory = $true)]
    [string]$ContextPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -LiteralPath $ContextPath)) {
    throw "Execution Context introuvable."
}

try {
    $Raw = Get-Content -LiteralPath $ContextPath -Raw -Encoding UTF8
    $Context = $Raw | ConvertFrom-Json
}
catch {
    throw "Execution Context invalide : $($_.Exception.Message)"
}

$Required = @(
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
    "mode"
)

foreach ($Field in $Required) {

    if (
        (-not ($Context.PSObject.Properties.Name -contains $Field)) -or
        [string]::IsNullOrWhiteSpace([string]$Context.$Field)
    ) {
        throw "Champ obligatoire absent ou vide : $Field"
    }
}

if ($Context.security.tenantIsolation -ne $true) {
    throw "Tenant isolation invalide."
}

if ($Context.security.clientIsolation -ne $true) {
    throw "Client isolation invalide."
}

if ($Context.security.projectIsolation -ne $true) {
    throw "Project isolation invalide."
}

if ($Context.security.authorizationRequired -ne $true) {
    throw "Authorization requirement invalide."
}

if ($Context.security.secretExposureToWorker -ne $false) {
    throw "Secret exposure doit rester FALSE."
}

$Handoff = [ordered]@{
    schema = "BK-AI-WORKERS-EXECUTION-HANDOFF"
    version = "7H-14"

    executionId = $Context.executionId
    correlationId = $Context.correlationId

    tenantId = $Context.tenantId
    clientId = $Context.clientId
    projectId = $Context.projectId

    workerId = $Context.workerId
    skillId = $Context.skillId
    taskId = $Context.taskId
    toolId = $Context.toolId
    action = $Context.action

    mode = $Context.mode

    receivedAt = (Get-Date).ToString("o")

    sourceContext = $ContextPath

    security = [ordered]@{
        tenantIsolation = $true
        clientIsolation = $true
        projectIsolation = $true
        secretExposureToWorker = $false
        authorizationRequired = $true
        capabilityAlreadyChecked = $true
    }

    financial = [ordered]@{
        autonomousCommitAllowed = $false
        approvalRequired = $false
    }

    runtime = [ordered]@{
        handoffAccepted = $true
        executionAllowed = $false
    }
}

$Json = $Handoff | ConvertTo-Json -Depth 12

return [PSCustomObject]@{
    handoffAccepted = $true
    executionId = $Context.executionId
    correlationId = $Context.correlationId
    handoff = $Handoff
}