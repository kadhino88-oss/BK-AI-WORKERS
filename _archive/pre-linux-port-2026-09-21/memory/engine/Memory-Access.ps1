param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("READ", "WRITE")]
    [string]$Action,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$ProjectId,

    [Parameter(Mandatory = $true)]
    [string]$WorkerId,

    [Parameter(Mandatory = $true)]
    [string]$MemoryKey,

    [string]$Value
)

$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$RuntimePath = Join-Path $Root "memory\runtime"
$DataPath = Join-Path $Root "memory\data"

function Get-Context {

    $files = Get-ChildItem $RuntimePath -Filter "CTX-*.json" -File

    foreach ($file in $files) {

        try {
            $context = Get-Content $file.FullName -Raw | ConvertFrom-Json

            if (
                $context.client_id -eq $ClientId -and
                $context.project_id -eq $ProjectId -and
                $context.worker_id -eq $WorkerId
            ) {
                return $context
            }
        }
        catch {
            continue
        }
    }

    return $null
}

function Get-MemoryFile {

    $clientFolder = Join-Path $DataPath $ClientId
    $projectFolder = Join-Path $clientFolder $ProjectId
    $workerFolder = Join-Path $projectFolder $WorkerId

    if (-not (Test-Path $workerFolder)) {
        New-Item -ItemType Directory -Force $workerFolder | Out-Null
    }

    return Join-Path $workerFolder "$MemoryKey.json"
}

Write-Host ""
Write-Host "============================================"
Write-Host " MEMORY ACCESS ENGINE"
Write-Host "============================================"
Write-Host ""

$context = Get-Context

if ($null -eq $context) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : CONTEXTE NON AUTORISE"
    Write-Host "Client  : $ClientId"
    Write-Host "Projet  : $ProjectId"
    Write-Host "Worker  : $WorkerId"

    exit 10
}

if ($context.scope.client -ne $true) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : SCOPE CLIENT INVALIDE"

    exit 11
}

if ($context.scope.project -ne $true) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : SCOPE PROJET INVALIDE"

    exit 12
}

if ($context.scope.worker -ne $true) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : SCOPE WORKER INVALIDE"

    exit 13
}

$memoryFile = Get-MemoryFile

if ($Action -eq "READ") {

    if (-not (Test-Path $memoryFile)) {

        Write-Host "ACCESS : AUTORISE"
        Write-Host "MEMORY : VIDE"
        Write-Host "STATUS : READY"

        exit 0
    }

    try {

        $memory = Get-Content $memoryFile -Raw | ConvertFrom-Json

        Write-Host "ACCESS : AUTORISE"
        Write-Host "MEMORY : TROUVEE"
        Write-Host ""
        Write-Host "Client  : $ClientId"
        Write-Host "Projet  : $ProjectId"
        Write-Host "Worker  : $WorkerId"
        Write-Host "Key     : $MemoryKey"
        Write-Host "Value   : $($memory.value)"
        Write-Host ""

        exit 0
    }
    catch {

        Write-Host "ACCESS : ERROR"
        Write-Host "RAISON : MEMOIRE INVALIDE"

        exit 20
    }
}

if ($Action -eq "WRITE") {

    if ($context.permissions.write -ne $true) {

        Write-Host "ACCESS : REFUSE"
        Write-Host "RAISON : WRITE NON AUTORISE"

        exit 14
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {

        Write-Host "ACCESS : REFUSE"
        Write-Host "RAISON : VALUE MANQUANTE"

        exit 15
    }

    $memory = [ordered]@{
        memory_key = $MemoryKey
        client_id = $ClientId
        project_id = $ProjectId
        worker_id = $WorkerId
        value = $Value
        updated_at = (Get-Date).ToUniversalTime().ToString("o")
    }

    $memory | ConvertTo-Json -Depth 10 | Set-Content $memoryFile -Encoding UTF8

    Write-Host "ACCESS : AUTORISE"
    Write-Host "MEMORY : ECRITE"
    Write-Host ""
    Write-Host "Client  : $ClientId"
    Write-Host "Projet  : $ProjectId"
    Write-Host "Worker  : $WorkerId"
    Write-Host "Key     : $MemoryKey"
    Write-Host "STATUS  : SUCCESS"

    exit 0
}

Write-Host "ACTION INVALIDE"

exit 30