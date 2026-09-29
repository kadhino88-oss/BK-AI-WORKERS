$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\dead-letter-recovery\DEAD-LETTER-RECOVERY-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\dead-letter-recovery\state\dead-letter-queue.jsonl"

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

Reset-DeadLetterState | Out-Null

# 1
$config = Get-DeadLetterConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Dead Letter valide"

# 2
Assert-Pass (
    $config.deadLetterEnabled -eq $true -and
    $config.recoveryEnabled -eq $true -and
    $config.replayEnabled -eq $true
) "DLQ recovery et replay actives"

# 3
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 4
$entry = New-DeadLetterEntry `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -ConnectorId "connector-A" `
    -FailureCode "TIMEOUT" `
    -FailureMessage "controlled timeout" `
    -Retryable $true `
    -Attempt 1

Assert-Pass (
    $entry.EntryId -and
    $entry.Status -eq "PENDING" -and
    $entry.Retryable -eq $true
) "entrée DLQ correctement generee"

# 5
$added = Add-DeadLetterEntry -Entry $entry

Assert-Pass (
    $added -eq $true
) "entrée DLQ correctement enregistree"

# 6
$loaded = @(Get-DeadLetterEntries -TenantId "tenant-A")

Assert-Pass (
    $loaded.Count -eq 1 -and
    $loaded[0].ExecutionId -eq "exec-001"
) "lecture DLQ correctement executee"

# 7
$decisionRetry = Get-RecoveryDecision -Entry $entry

Assert-Pass (
    $decisionRetry.Action -eq "REPLAY"
) "decision retry correctement determinee"

# 8
$nonRetry = New-DeadLetterEntry `
    -ExecutionId "exec-002" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -ConnectorId "connector-A" `
    -FailureCode "VALIDATION_ERROR" `
    -FailureMessage "controlled validation failure" `
    -Retryable $false `
    -Attempt 1

$decisionNoRetry = Get-RecoveryDecision -Entry $nonRetry

Assert-Pass (
    $decisionNoRetry.Action -eq "DLQ"
) "erreur non retryable correctement maintenue en DLQ"

# 9
$addedNonRetry = Add-DeadLetterEntry -Entry $nonRetry

Assert-Pass (
    $addedNonRetry -eq $true
) "entrée non retryable correctement enregistree"

# 10
$otherTenant = @(Get-DeadLetterEntries -TenantId "tenant-B")

Assert-Pass (
    $otherTenant.Count -eq 0
) "isolation tenant correctement appliquee"

# 11
$replayed = Replay-DeadLetterEntry -EntryId $entry.EntryId

Assert-Pass (
    $null -ne $replayed -and
    $replayed.Status -eq "REPLAYED" -and
    $replayed.Attempt -eq 2
) "replay DLQ correctement execute"

# 12
$replayedList = @(Get-DeadLetterEntries -TenantId "tenant-A" -Status "REPLAYED")

Assert-Pass (
    $replayedList.Count -eq 1
) "entrée replay correctement retrouvee"

# 13
$resolved = Resolve-DeadLetterEntry -EntryId $entry.EntryId

Assert-Pass (
    $resolved -eq $true
) "resolution DLQ correctement executee"

# 14
$resolvedList = @(Get-DeadLetterEntries -Status "RESOLVED")

Assert-Pass (
    $resolvedList.Count -eq 1 -and
    $resolvedList[0].Status -eq "RESOLVED"
) "entrée resolue correctement persistee"

# 15
$maxAttempt = New-DeadLetterEntry `
    -ExecutionId "exec-003" `
    -TenantId "tenant-C" `
    -ClientId "client-C" `
    -ProjectId "project-C" `
    -WorkerId "worker-C" `
    -ConnectorId "connector-C" `
    -FailureCode "RETRY_EXHAUSTED" `
    -FailureMessage "controlled retry exhaustion" `
    -Retryable $true `
    -Attempt 3

$decisionMax = Get-RecoveryDecision -Entry $maxAttempt

Assert-Pass (
    $decisionMax.Action -eq "DLQ"
) "maximum de tentatives correctement bloque"

# 16
$invalid = $false

try {

    New-DeadLetterEntry `
        -ExecutionId "" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -ConnectorId "connector-A" `
        -FailureCode "ERROR" `
        -FailureMessage "bad" `
        -Retryable $true `
        -Attempt 1 | Out-Null
}
catch {
    $invalid = $true
}

Assert-Pass $invalid `
    "execution id vide correctement bloque"

# 17
$invalidAttempt = $false

try {

    New-DeadLetterEntry `
        -ExecutionId "exec-bad" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -ConnectorId "connector-A" `
        -FailureCode "ERROR" `
        -FailureMessage "bad" `
        -Retryable $true `
        -Attempt 0 | Out-Null
}
catch {
    $invalidAttempt = $true
}

Assert-Pass $invalidAttempt `
    "attempt invalide correctement bloque"

# 18
$secretBlocked = $false

try {

    $secretEntry = New-DeadLetterEntry `
        -ExecutionId "exec-secret" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -ConnectorId "connector-A" `
        -FailureCode "SECRET_TEST" `
        -FailureMessage "token=password-secret" `
        -Retryable $false `
        -Attempt 1

    Add-DeadLetterEntry -Entry $secretEntry | Out-Null
}
catch {
    $secretBlocked = $true
}

Assert-Pass $secretBlocked `
    "secret correctement bloque dans la DLQ"

# 19
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "DLQ sans secret"

# 20
$globalEntries = @(Get-DeadLetterEntries)

Assert-Pass (
    $globalEntries.Count -eq 2
) "lecture globale DLQ correcte"

# 21
$pending = @(Get-DeadLetterEntries -Status "PENDING")

Assert-Pass (
    $pending.Count -eq 1 -and
    $pending[0].ExecutionId -eq "exec-002"
) "filtrage PENDING correctement execute"

# 22
Reset-DeadLetterState | Out-Null

Assert-Pass (
    @(Get-DeadLetterEntries).Count -eq 0
) "reset DLQ correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-36" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Dead Letter Queue & Failed Execution Recovery Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"