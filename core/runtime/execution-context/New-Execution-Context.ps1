param(
    [string]$TenantId,
    [string]$ClientId,
    [string]$ProjectId,
    [string]$WorkerId,
    [string]$SkillId,
    [string]$TaskId,
    [string]$ToolId,
    [string]$Action,
    [string]$Mode = "SIMULATION"
)

$ErrorActionPreference = "Stop"

$ContextDir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-context"

function Require-Value {
    param(
        [string]$Name,
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name est obligatoire."
    }
}

Require-Value "TenantId" $TenantId
Require-Value "ClientId" $ClientId
Require-Value "ProjectId" $ProjectId
Require-Value "WorkerId" $WorkerId
Require-Value "SkillId" $SkillId
Require-Value "TaskId" $TaskId
Require-Value "ToolId" $ToolId
Require-Value "Action" $Action

$ExecutionId = "EXEC-" + [Guid]::NewGuid().ToString()
$CorrelationId = "CORR-" + [Guid]::NewGuid().ToString()

$Context = [ordered]@{
    schema = "BK-AI-WORKERS-EXECUTION-CONTEXT"
    version = "7H-13"

    executionId = $ExecutionId
    correlationId = $CorrelationId

    tenantId = $TenantId
    clientId = $ClientId
    projectId = $ProjectId

    workerId = $WorkerId
    skillId = $SkillId
    taskId = $TaskId
    toolId = $ToolId
    action = $Action

    mode = $Mode
    createdAt = (Get-Date).ToString("o")

    security = [ordered]@{
        tenantIsolation = $true
        clientIsolation = $true
        projectIsolation = $true
        authorizationRequired = $true
        secretExposureToWorker = $false
    }

    financial = [ordered]@{
        approvalRequired = $false
        autonomousCommitAllowed = $false
    }

    metadata = [ordered]@{
        runtime = "BK-AI-WORKERS"
        contextVersion = "7H-13"
    }
}

$Json = $Context | ConvertTo-Json -Depth 12

# ------------------------------------------------------------
# DETECTION DES VRAIES VALEURS DE SECRET
# ------------------------------------------------------------

$ForbiddenValuePatterns = @(
    '^sk-[A-Za-z0-9]{10,}$',
    '^Bearer\s+[A-Za-z0-9\-_\.]+$',
    '^AKIA[A-Z0-9]{16}$'
)

function Inspect-StringValues {
    param(
        [object]$Value,
        [string]$Path = "root"
    )

    if ($null -eq $Value) {
        return
    }

    if ($Value -is [string]) {

        foreach ($Pattern in $ForbiddenValuePatterns) {

            if ([regex]::IsMatch($Value, $Pattern)) {
                throw "Valeur potentiellement secrete detectee dans : $Path"
            }
        }

        return
    }

    if ($Value -is [System.Collections.IDictionary]) {

        foreach ($Key in $Value.Keys) {
            Inspect-StringValues `
                -Value $Value[$Key] `
                -Path "$Path.$Key"
        }

        return
    }

    if ($Value -is [System.Collections.IEnumerable]) {

        foreach ($Item in $Value) {
            Inspect-StringValues `
                -Value $Item `
                -Path "$Path[]"
        }

        return
    }

    $Properties = $Value.PSObject.Properties

    foreach ($Property in $Properties) {

        Inspect-StringValues `
            -Value $Property.Value `
            -Path "$Path.$($Property.Name)"
    }
}

Inspect-StringValues -Value $Context

$OutputPath = Join-Path `
    $ContextDir `
    "$ExecutionId.json"

[System.IO.File]::WriteAllText(
    $OutputPath,
    $Json,
    [System.Text.UTF8Encoding]::new($false)
)

[PSCustomObject]@{
    executionId = $ExecutionId
    correlationId = $CorrelationId
    path = $OutputPath
}