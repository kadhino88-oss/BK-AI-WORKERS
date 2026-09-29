param(
    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$TaskId
)

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$RuntimePath = Join-Path $Root "memory\runtime"
$OutputPath = Join-Path $RuntimePath "ACTIVE-$TaskId.json"

$contexts = Get-ChildItem $RuntimePath -Filter "CTX-*.json" -File

$activeContext = $null

foreach ($file in $contexts) {

    try {

        $context = Get-Content $file.FullName -Raw | ConvertFrom-Json

        if (
            $context.client_id -eq $ClientId -and
            $context.project_id -eq $ProjectId -and
            $context.worker_id -eq $WorkerId -and
            $context.task_id -eq $TaskId
        ) {
            $activeContext = $context
            break
        }
    }
    catch {
        continue
    }
}

if ($null -eq $activeContext) {

    Write-Host ""
    Write-Host "CONTEXT BUILDER : REFUSE"
    Write-Host "RAISON : CONTEXTE INTROUVABLE"
    exit 10
}

$activeMemory = [ordered]@{

    context_id = $activeContext.context_id

    client = [ordered]@{
        id = $activeContext.client_id
    }

    project = [ordered]@{
        id = $activeContext.project_id
    }

    worker = [ordered]@{
        id = $activeContext.worker_id
    }

    task = [ordered]@{
        id = $activeContext.task_id
        objective = $activeContext.objective
    }

    permissions = [ordered]@{
        read = $activeContext.permissions.read
        write = $activeContext.permissions.write
        external_actions = $activeContext.permissions.external_actions
        financial_actions = $activeContext.permissions.financial_actions
    }

    generated_at = (Get-Date).ToUniversalTime().ToString("o")
}

$activeMemory |
    ConvertTo-Json -Depth 10 |
    Set-Content $OutputPath -Encoding UTF8

Write-Host ""
Write-Host "============================================"
Write-Host " CONTEXT BUILDER"
Write-Host "============================================"
Write-Host ""

Write-Host "CONTEXT : $($activeContext.context_id)"
Write-Host "CLIENT  : $ClientId"
Write-Host "PROJECT : $ProjectId"
Write-Host "WORKER  : $WorkerId"
Write-Host "TASK    : $TaskId"
Write-Host ""
Write-Host "ACTIVE CONTEXT : CREATED"
Write-Host "OUTPUT : $OutputPath"
Write-Host ""
Write-Host "STATUS : READY"

exit 0