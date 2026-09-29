param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("WRITE", "READ", "UPDATE", "DELETE")]
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

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"

$RuntimePath = Join-Path $Root "memory\runtime"
$DataPath = Join-Path $Root "memory\data"

Write-Host ""
Write-Host "============================================"
Write-Host " MEMORY LIFECYCLE ENGINE"
Write-Host " PHASE 5F"
Write-Host "============================================"
Write-Host ""

# -------------------------------------------------
# RECHERCHE DU CONTEXTE AUTORISE
# -------------------------------------------------

$contexts = Get-ChildItem $RuntimePath -Filter "CTX-*.json" -File

$authorizedContext = $null

foreach ($file in $contexts) {

    try {

        $context = Get-Content $file.FullName -Raw | ConvertFrom-Json

        if (
            $context.client_id -eq $ClientId -and
            $context.project_id -eq $ProjectId -and
            $context.worker_id -eq $WorkerId
        ) {
            $authorizedContext = $context
            break
        }
    }
    catch {
        continue
    }
}

if ($null -eq $authorizedContext) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : CONTEXTE NON AUTORISE"

    exit 10
}

# -------------------------------------------------
# VERIFICATION DES PERMISSIONS
# -------------------------------------------------

if ($authorizedContext.scope.client -ne $true) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : SCOPE CLIENT INVALIDE"

    exit 11
}

if ($authorizedContext.scope.project -ne $true) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : SCOPE PROJET INVALIDE"

    exit 12
}

if ($authorizedContext.scope.worker -ne $true) {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : SCOPE WORKER INVALIDE"

    exit 13
}

if ($authorizedContext.permissions.write -ne $true -and $Action -ne "READ") {

    Write-Host "ACCESS : REFUSE"
    Write-Host "RAISON : WRITE NON AUTORISE"

    exit 14
}

# -------------------------------------------------
# CHEMIN MEMOIRE
# -------------------------------------------------

$WorkerPath = Join-Path $DataPath "$ClientId\$ProjectId\$WorkerId"

if (-not (Test-Path $WorkerPath)) {

    New-Item -ItemType Directory -Force $WorkerPath | Out-Null
}

$MemoryFile = Join-Path $WorkerPath "$MemoryKey.json"

# -------------------------------------------------
# READ
# -------------------------------------------------

if ($Action -eq "READ") {

    if (-not (Test-Path $MemoryFile)) {

        Write-Host "MEMORY : ABSENTE"
        Write-Host "STATUS : EMPTY"

        exit 0
    }

    try {

        $memory = Get-Content $MemoryFile -Raw | ConvertFrom-Json

        Write-Host "ACCESS : AUTORISE"
        Write-Host "MEMORY : TROUVEE"
        Write-Host ""
        Write-Host "KEY   : $MemoryKey"
        Write-Host "VALUE : $($memory.value)"
        Write-Host "UPDATED : $($memory.updated_at)"
        Write-Host ""

        exit 0
    }
    catch {

        Write-Host "ACCESS : ERROR"
        Write-Host "RAISON : JSON MEMOIRE INVALIDE"

        exit 20
    }
}

# -------------------------------------------------
# WRITE
# -------------------------------------------------

if ($Action -eq "WRITE") {

    if ([string]::IsNullOrWhiteSpace($Value)) {

        Write-Host "ACCESS : REFUSE"
        Write-Host "RAISON : VALUE MANQUANTE"

        exit 15
    }

    if (Test-Path $MemoryFile) {

        Write-Host "MEMORY : EXISTE DEJA"
        Write-Host "UTILISER UPDATE POUR LA MODIFIER"

        exit 16
    }

    $memory = [ordered]@{

        memory_key = $MemoryKey

        client_id = $ClientId

        project_id = $ProjectId

        worker_id = $WorkerId

        value = $Value

        created_at = (Get-Date).ToUniversalTime().ToString("o")

        updated_at = (Get-Date).ToUniversalTime().ToString("o")
    }

    $memory |
        ConvertTo-Json -Depth 10 |
        Set-Content $MemoryFile -Encoding UTF8

    Write-Host "MEMORY : CREATED"
    Write-Host "KEY : $MemoryKey"
    Write-Host "STATUS : SUCCESS"

    exit 0
}

# -------------------------------------------------
# UPDATE
# -------------------------------------------------

if ($Action -eq "UPDATE") {

    if (-not (Test-Path $MemoryFile)) {

        Write-Host "MEMORY : INTROUVABLE"
        Write-Host "UTILISER WRITE POUR LA CREER"

        exit 17
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {

        Write-Host "ACCESS : REFUSE"
        Write-Host "RAISON : VALUE MANQUANTE"

        exit 15
    }

    try {

        $memory = Get-Content $MemoryFile -Raw | ConvertFrom-Json

        $memory.value = $Value

        $memory.updated_at =
            (Get-Date).ToUniversalTime().ToString("o")

        $memory |
            ConvertTo-Json -Depth 10 |
            Set-Content $MemoryFile -Encoding UTF8

        Write-Host "MEMORY : UPDATED"
        Write-Host "KEY : $MemoryKey"
        Write-Host "STATUS : SUCCESS"

        exit 0
    }
    catch {

        Write-Host "MEMORY : UPDATE ERROR"

        exit 20
    }
}

# -------------------------------------------------
# DELETE
# -------------------------------------------------

if ($Action -eq "DELETE") {

    if (-not (Test-Path $MemoryFile)) {

        Write-Host "MEMORY : ABSENTE"
        Write-Host "STATUS : NOTHING TO DELETE"

        exit 0
    }

    Remove-Item $MemoryFile -Force

    Write-Host "MEMORY : DELETED"
    Write-Host "KEY : $MemoryKey"
    Write-Host "STATUS : SUCCESS"

    exit 0
}

Write-Host "ACTION INVALIDE"

exit 30