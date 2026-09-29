$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-checkpoint\EXECUTION-CHECKPOINT-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-checkpoint\state\checkpoints.json"

. $Runtime

$pass = 0
$fail = 0

function Assert-Pass {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if ($Condition) {
        Write-Host "PASS : $Message" -ForegroundColor Green
        $script:pass++
    }
    else {
        Write-Host "FAIL : $Message" -ForegroundColor Red
        $script:fail++
    }
}

Reset-CheckpointState | Out-Null

# 1
$config = Get-CheckpointConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Checkpoint valide"

# 2
Assert-Pass (
    $config.checkpointEnabled -eq $true -and
    $config.resumeEnabled -eq $true
) "checkpoint et resume actifs"

# 3
Assert-Pass (
    $config.maxCheckpointsPerExecution -eq 20 -and
    $config.maxExecutions -eq 5000
) "limites checkpoint correctement configurees"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$cp1 = New-Checkpoint `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Sequence 1 `
    -Stage "planning" `
    -Status "READY" `
    -StateHash "hash-A-001"

Assert-Pass (
    $cp1.CheckpointId -and
    $cp1.ExecutionId -eq "exec-001" -and
    $cp1.Sequence -eq 1
) "checkpoint correctement genere"

# 6
$saved1 = Save-Checkpoint -Checkpoint $cp1

Assert-Pass (
    $saved1 -eq $true
) "checkpoint correctement persiste"

# 7
$loaded = @(Get-Checkpoints -ExecutionId "exec-001")

Assert-Pass (
    $loaded.Count -eq 1 -and
    $loaded[0].Stage -eq "planning"
) "checkpoint correctement relu"

# 8
$cp2 = New-Checkpoint `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Sequence 2 `
    -Stage "execution" `
    -Status "READY" `
    -StateHash "hash-A-002"

Save-Checkpoint -Checkpoint $cp2 | Out-Null

Assert-Pass (
    @(Get-Checkpoints -ExecutionId "exec-001").Count -eq 2
) "plusieurs checkpoints correctement geres"

# 9
$latest = Get-LatestCheckpoint `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $null -ne $latest -and
    $latest.Sequence -eq 2 -and
    $latest.Stage -eq "execution"
) "dernier checkpoint correctement determine"

# 10
$validation = Validate-Checkpoint `
    -CheckpointId $cp1.CheckpointId `
    -TenantId "tenant-A"

Assert-Pass (
    $validation.Valid -eq $true
) "checkpoint correctement valide"

# 11
$marked = Mark-CheckpointValidated `
    -CheckpointId $cp1.CheckpointId `
    -TenantId "tenant-A"

Assert-Pass (
    $marked -eq $true
) "validation checkpoint correctement persistee"

# 12
$resume = Resume-FromCheckpoint `
    -CheckpointId $cp1.CheckpointId `
    -TenantId "tenant-A"

Assert-Pass (
    $resume.Resumed -eq $true -and
    $resume.ExecutionId -eq "exec-001" -and
    $resume.Sequence -eq 1
) "resume depuis checkpoint correctement execute"

# 13
$wrongTenant = Test-CheckpointTenantIsolation `
    -CheckpointId $cp1.CheckpointId `
    -TenantId "tenant-B"

Assert-Pass (
    $wrongTenant -eq $false
) "isolation tenant correctement appliquee"

# 14
$tenantBCheckpoint = New-Checkpoint `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B" `
    -Sequence 1 `
    -Stage "planning" `
    -Status "READY" `
    -StateHash "hash-B-001"

Save-Checkpoint -Checkpoint $tenantBCheckpoint | Out-Null

$tenantAList = @(Get-Checkpoints -TenantId "tenant-A")

Assert-Pass (
    $tenantAList.Count -eq 2
) "filtrage tenant correctement applique"

# 15
$projectList = @(Get-Checkpoints -ProjectId "project-A")

Assert-Pass (
    $projectList.Count -eq 2
) "filtrage project correctement applique"

# 16
$invalidExecution = $false

try {
    New-Checkpoint `
        -ExecutionId "" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -Sequence 1 `
        -Stage "test" `
        -Status "READY" `
        -StateHash "hash-X" | Out-Null
}
catch {
    $invalidExecution = $true
}

Assert-Pass $invalidExecution `
    "execution id vide correctement bloquee"

# 17
$invalidSequence = $false

try {
    New-Checkpoint `
        -ExecutionId "exec-bad" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -Sequence (-1) `
        -Stage "test" `
        -Status "READY" `
        -StateHash "hash-X" | Out-Null
}
catch {
    $invalidSequence = $true
}

Assert-Pass $invalidSequence `
    "sequence negative correctement bloquee"

# 18
$invalidState = $false

try {
    New-Checkpoint `
        -ExecutionId "exec-bad-state" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -Sequence 1 `
        -Stage "test" `
        -Status "READY" `
        -StateHash "" | Out-Null
}
catch {
    $invalidState = $true
}

Assert-Pass $invalidState `
    "state hash vide correctement bloque"

# 19
$notFound = Validate-Checkpoint `
    -CheckpointId "unknown-checkpoint" `
    -TenantId "tenant-A"

Assert-Pass (
    $notFound.Valid -eq $false
) "checkpoint inconnu correctement refuse"

# 20
$unvalidatedResume = Resume-FromCheckpoint `
    -CheckpointId $cp2.CheckpointId `
    -TenantId "tenant-A"

Assert-Pass (
    $unvalidatedResume.Resumed -eq $false
) "resume checkpoint non valide correctement bloque"

# 21
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat checkpoint sans secret"

# 22
$loadedB = @(Get-Checkpoints -TenantId "tenant-B")

Assert-Pass (
    $loadedB.Count -eq 1 -and
    $loadedB[0].TenantId -eq "tenant-B"
) "donnees tenant B correctement isolees"

# 23
$cp1Reloaded = Get-Checkpoints `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" |
    Where-Object CheckpointId -eq $cp1.CheckpointId |
    Select-Object -First 1

Assert-Pass (
    $null -ne $cp1Reloaded -and
    $cp1Reloaded.ValidatedAtUtc -and
    $cp1Reloaded.ResumedAtUtc
) "validation et reprise correctement tracees"

# 24
Reset-CheckpointState | Out-Null

Assert-Pass (
    @(Get-Checkpoints).Count -eq 0
) "reset Checkpoint Manager correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-41" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Checkpoint & Resume Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"