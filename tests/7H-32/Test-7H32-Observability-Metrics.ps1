$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\observability-metrics\OBSERVABILITY-METRICS-RUNTIME.ps1"
$Events = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\observability-metrics\state\metrics.jsonl"

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

Reset-MetricState | Out-Null

$config = Get-ObservabilityConfig

Assert-Pass ($config.version -eq "1.0" -and $config.enabled -eq $true -and $config.metricsEnabled -eq $true) `
    "configuration observabilite valide"

Assert-Pass ($config.captureSecrets -eq $false -and $config.capturePrompts -eq $false -and $config.capturePayloads -eq $false) `
    "capture sensible desactivee"

$event1 = New-MetricEvent `
    -MetricName "task.execution" `
    -Status "SUCCESS" `
    -DurationMs 120 `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Operation "run-task"

Assert-Pass ($null -ne $event1.EventId -and $event1.TimestampUtc -and $event1.DurationMs -eq 120) `
    "evenement metrique correctement genere"

Assert-Pass (
    $event1.MetricName -eq "task.execution" -and
    $event1.Status -eq "SUCCESS" -and
    $event1.TenantId -eq "tenant-A"
) "contenu metrique valide"

Assert-Pass ((Write-MetricEvent -Event $event1) -eq $true) `
    "evenement metrique ecrit"

$event2 = New-MetricEvent `
    -MetricName "task.execution" `
    -Status "ERROR" `
    -DurationMs 80 `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Operation "run-task"

Write-MetricEvent -Event $event2 | Out-Null

$event3 = New-MetricEvent `
    -MetricName "task.execution" `
    -Status "BLOCKED" `
    -DurationMs 40 `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B" `
    -Operation "run-task"

Write-MetricEvent -Event $event3 | Out-Null

$eventsA = @(Get-MetricEvents -TenantId "tenant-A")

Assert-Pass ($eventsA.Count -eq 2) `
    "filtrage par tenant correctement applique"

$eventsB = @(Get-MetricEvents -TenantId "tenant-B")

Assert-Pass ($eventsB.Count -eq 1 -and $eventsB[0].TenantId -eq "tenant-B") `
    "isolation tenant correctement appliquee"

$summaryA = Get-MetricSummary -TenantId "tenant-A" -MetricName "task.execution"

Assert-Pass (
    $summaryA.Count -eq 2 -and
    $summaryA.SuccessCount -eq 1 -and
    $summaryA.ErrorCount -eq 1
) "compteurs de statut correctement calcules"

Assert-Pass ($summaryA.AvgDurationMs -eq 100) `
    "duree moyenne correctement calculee"

Assert-Pass ($summaryA.MinDurationMs -eq 80 -and $summaryA.MaxDurationMs -eq 120) `
    "min/max de latence correctement calcules"

$clientFiltered = @(Get-MetricEvents -TenantId "tenant-A" -ClientId "client-A")

Assert-Pass ($clientFiltered.Count -eq 2) `
    "filtrage client correctement applique"

$projectFiltered = @(Get-MetricEvents -TenantId "tenant-A" -ClientId "client-A" -ProjectId "project-A")

Assert-Pass ($projectFiltered.Count -eq 2) `
    "filtrage projet correctement applique"

$workerFiltered = @(Get-MetricEvents -TenantId "tenant-A" -WorkerId "worker-A")

Assert-Pass ($workerFiltered.Count -eq 2) `
    "filtrage worker correctement applique"

$metricFiltered = @(Get-MetricEvents -MetricName "task.execution")

Assert-Pass ($metricFiltered.Count -eq 3) `
    "filtrage par nom de metrique correctement applique"

$privacyRaw = ""
if (Test-Path -LiteralPath $Events) {
    $privacyRaw = Get-Content -LiteralPath $Events -Raw -Encoding UTF8
}

Assert-Pass (
    $privacyRaw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "journal metrique sans secret"

$invalidBlocked = $false

try {
    New-MetricEvent `
        -MetricName "bad.metric" `
        -Status "SUCCESS" `
        -DurationMs (-1) `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -Operation "bad"
}
catch {
    $invalidBlocked = $true
}

Assert-Pass $invalidBlocked `
    "duree negative correctement bloquee"

$invalidContext = $false

try {
    New-MetricEvent `
        -MetricName "bad.metric" `
        -Status "SUCCESS" `
        -DurationMs 10 `
        -TenantId "" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -Operation "bad"
}
catch {
    $invalidContext = $true
}

Assert-Pass $invalidContext `
    "contexte tenant incomplet correctement bloque"

$invalidField = $false

try {
    $badEvent = [ordered]@{
        EventId = [Guid]::NewGuid().ToString()
        TimestampUtc = (Get-Date).ToUniversalTime().ToString("o")
        MetricName = "bad.metric"
        Status = "SUCCESS"
        DurationMs = 10
        TenantId = "tenant-A"
        ClientId = "client-A"
        ProjectId = "project-A"
        WorkerId = "worker-A"
        Operation = "bad"
        Secret = "should-not-exist"
    }

    Write-MetricEvent -Event $badEvent
}
catch {
    $invalidField = $true
}

Assert-Pass $invalidField `
    "champ non autorise correctement bloque"

$beforeReset = @(Get-MetricEvents)

Assert-Pass ($beforeReset.Count -eq 3) `
    "lecture globale des metriques correcte"

Reset-MetricState | Out-Null

$afterReset = @(Get-MetricEvents)

Assert-Pass ($afterReset.Count -eq 0) `
    "reset des etats metriques correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-32" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {
    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Observability & Metrics Manager operationnel." -ForegroundColor Green
    exit 0
}
else {
    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
    exit 1
}