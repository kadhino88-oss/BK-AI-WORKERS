$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-state-integrity\EXECUTION-STATE-INTEGRITY-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-state-integrity\state\execution-states.json"

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

Reset-StateIntegrity | Out-Null

# 1
$config = Get-StateIntegrityConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration State Integrity valide"

# 2
Assert-Pass (
    $config.integrityEnabled -eq $true -and
    $config.versioningEnabled -eq $true
) "integrite et versioning actifs"

# 3
Assert-Pass (
    $config.maxVersionsPerExecution -eq 50 -and
    $config.maxExecutions -eq 5000
) "limites correctement configurees"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$state1 = New-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Version 1 `
    -Stage "planning" `
    -Status "READY" `
    -StateData @{
        Task = "planning"
        Step = 1
    }

Assert-Pass (
    $state1.ExecutionId -eq "exec-001" -and
    $state1.Version -eq 1 -and
    $state1.StateHash
) "state initial correctement genere"

# 6
$saved1 = Save-ExecutionState -State $state1

Assert-Pass (
    $saved1 -eq $true
) "state initial correctement persiste"

# 7
$states1 = @(Get-ExecutionStates -ExecutionId "exec-001")

Assert-Pass (
    $states1.Count -eq 1 -and
    $states1[0].Version -eq 1
) "state correctement relu"

# 8
$integrity1 = Test-StateIntegrity `
    -ExecutionId "exec-001" `
    -Version 1 `
    -TenantId "tenant-A"

Assert-Pass (
    $integrity1.Valid -eq $true
) "integrite du state correctement validee"

# 9
$state2 = New-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Version 2 `
    -Stage "execution" `
    -Status "RUNNING" `
    -StateData @{
        Task = "execution"
        Step = 2
    }

Save-ExecutionState -State $state2 | Out-Null

Assert-Pass (
    @(Get-ExecutionStates -ExecutionId "exec-001").Count -eq 2
) "versioning state correctement gere"

# 10
$latest = Get-LatestExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $null -ne $latest -and
    $latest.Version -eq 2 -and
    $latest.Stage -eq "execution"
) "dernier state correctement determine"

# 11
$updated = Update-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -Version 2 `
    -Stage "completed" `
    -Status "COMPLETED" `
    -StateData @{
        Task = "completed"
        Step = 3
    }

Assert-Pass (
    $updated -eq $true
) "mise a jour state correctement executee"

# 12
$latest2 = Get-LatestExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $latest2.Version -eq 3 -and
    $latest2.Status -eq "COMPLETED"
) "nouvelle version correctement creee"

# 13
$wrongTenant = Test-StateIntegrity `
    -ExecutionId "exec-001" `
    -Version 3 `
    -TenantId "tenant-B"

Assert-Pass (
    $wrongTenant.Valid -eq $false
) "isolation tenant correctement appliquee"

# 14
$tenantB = New-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B" `
    -Version 1 `
    -Stage "planning" `
    -Status "READY" `
    -StateData @{
        Task = "tenant-b"
    }

Save-ExecutionState -State $tenantB | Out-Null

$tenantAStates = @(Get-ExecutionStates -TenantId "tenant-A")

Assert-Pass (
    $tenantAStates.Count -eq 3
) "filtrage tenant correctement applique"

# 15
$projectStates = @(Get-ExecutionStates -ProjectId "project-A")

Assert-Pass (
    $projectStates.Count -eq 3
) "filtrage project correctement applique"

# 16
$badExecution = $false

try {
    New-ExecutionState `
        -ExecutionId "" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -Version 1 `
        -Stage "test" `
        -Status "READY" `
        -StateData @{ Test = 1 } | Out-Null
}
catch {
    $badExecution = $true
}

Assert-Pass $badExecution `
    "execution id vide correctement bloque"

# 17
$badVersion = $false

try {
    New-ExecutionState `
        -ExecutionId "exec-bad" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -Version 0 `
        -Stage "test" `
        -Status "READY" `
        -StateData @{ Test = 1 } | Out-Null
}
catch {
    $badVersion = $true
}

Assert-Pass $badVersion `
    "version invalide correctement bloquee"

# 18
$badState = $false

try {
    New-ExecutionState `
        -ExecutionId "exec-bad-state" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -Version 1 `
        -Stage "test" `
        -Status "READY" `
        -StateData $null | Out-Null
}
catch {
    $badState = $true
}

Assert-Pass $badState `
    "StateData vide correctement bloquee"

# 19
$notFound = Test-StateIntegrity `
    -ExecutionId "unknown-execution" `
    -Version 1 `
    -TenantId "tenant-A"

Assert-Pass (
    $notFound.Valid -eq $false
) "execution inconnue correctement refusee"

# 20
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "state persistent sans secret"

# 21
$hashValid = $latest2.StateHash -match '^[a-f0-9]{64}$'

Assert-Pass (
    $hashValid -eq $true
) "hash SHA-256 correctement forme"

# 22
$tamperMap = Get-StateMap

$keyToTamper = $tamperMap.Keys |
    Where-Object {
        [string](
            Get-StateField $tamperMap[$_] "ExecutionId"
        ) -eq "exec-001"
    } |
    Select-Object -First 1

$stateTamper = $tamperMap[$keyToTamper]

if ($stateTamper.StateData -is [System.Collections.IDictionary]) {
    $stateTamper.StateData["Task"] = "tampered"
}
else {
    $stateTamper.StateData = @{
        Task = "tampered"
    }
}

$tamperMap[$keyToTamper] = $stateTamper
Save-StateMap -Map $tamperMap | Out-Null

$tamperCheck = Test-StateIntegrity `
    -ExecutionId "exec-001" `
    -Version ([int](
        Get-StateField $stateTamper "Version"
    )) `
    -TenantId "tenant-A"

Assert-Pass (
    $tamperCheck.Valid -eq $false
) "modification d'etat correctement detectee"

Reset-StateIntegrity | Out-Null

Assert-Pass (
    @(Get-ExecutionStates).Count -eq 0
) "reset State Integrity correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-42" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution State Consistency & Integrity Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"