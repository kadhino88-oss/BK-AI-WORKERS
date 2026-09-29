$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\alerting-incidents\ALERTING-INCIDENTS-RUNTIME.ps1"

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

Reset-AlertState | Out-Null

# 1
$config = Get-AlertingConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Alerting valide"

# 2
Assert-Pass (
    $config.alertingEnabled -eq $true -and
    $config.incidentDetectionEnabled -eq $true
) "alerting et detection incidents actives"

# 3
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 4
$alert = New-Alert `
    -Type "TEST_ALERT" `
    -Severity "WARNING" `
    -Message "controlled alert" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Source "7H-34"

Assert-Pass (
    $alert.AlertId -and
    $alert.Status -eq "OPEN" -and
    $alert.Severity -eq "WARNING"
) "alerte correctement generee"

# 5
$write1 = Write-Alert -Alert $alert

Assert-Pass (
    $write1.Written -eq $true -and
    $write1.Deduplicated -eq $false
) "alerte correctement enregistree"

# 6
$loaded = @(Get-Alerts -TenantId "tenant-A")

Assert-Pass (
    $loaded.Count -eq 1 -and
    $loaded[0].Type -eq "TEST_ALERT"
) "lecture des alertes correctement executee"

# 7
$alertDuplicate = New-Alert `
    -Type "TEST_ALERT" `
    -Severity "WARNING" `
    -Message "second controlled alert" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -Source "7H-34"

$write2 = Write-Alert -Alert $alertDuplicate

Assert-Pass (
    $write2.Deduplicated -eq $true -and
    $write2.Written -eq $false
) "deduplication anti-spam correctement appliquee"

# 8
$isolation = @(Get-Alerts -TenantId "tenant-B")

Assert-Pass (
    $isolation.Count -eq 0
) "isolation tenant correctement appliquee"

# 9
$thresholdError = @(Test-IncidentThreshold -ErrorCount 5)

Assert-Pass (
    $thresholdError.Count -ge 1 -and
    $thresholdError[0].Triggered -eq $true -and
    $thresholdError[0].Type -eq "ERROR_THRESHOLD"
) "seuil erreurs correctement declenche"

# 10
$thresholdBlocked = @(Test-IncidentThreshold -BlockedCount 5)

Assert-Pass (
    $thresholdBlocked[0].Triggered -eq $true -and
    $thresholdBlocked[0].Type -eq "BLOCKED_THRESHOLD"
) "seuil blocages correctement declenche"

# 11
$thresholdLatency = @(Test-IncidentThreshold -LatencyMs 5000)

Assert-Pass (
    $thresholdLatency[0].Triggered -eq $true -and
    $thresholdLatency[0].Type -eq "LATENCY_THRESHOLD"
) "seuil latence correctement declenche"

# 12
$thresholdNone = @(Test-IncidentThreshold -ErrorCount 0 -BlockedCount 0 -LatencyMs 10)

Assert-Pass (
    $thresholdNone.Count -eq 1 -and
    $thresholdNone[0].Triggered -eq $false
) "absence de seuil correctement detectee"

# 13
$incidentAlert = New-Alert `
    -Type "INCIDENT_TEST" `
    -Severity "CRITICAL" `
    -Message "controlled incident" `
    -TenantId "tenant-X" `
    -ClientId "client-X" `
    -ProjectId "project-X" `
    -WorkerId "worker-X" `
    -Source "diagnostics"

$incidentResult = Open-Incident -Alert $incidentAlert

Assert-Pass (
    ($null -ne $incidentResult.Alert.IncidentId) -and
    (-not [string]::IsNullOrWhiteSpace([string]$incidentResult.Alert.IncidentId))
) "incident correctement ouvert"

# 14
$incidentList = @(Get-Alerts -TenantId "tenant-X" -Status "OPEN")

Assert-Pass (
    $incidentList.Count -eq 1 -and
    $incidentList[0].IncidentId
) "incident ouvert correctement retrouve"

# 15
$incidentId = [string]$incidentList[0].IncidentId

$closed = Close-Incident -IncidentId $incidentId

Assert-Pass (
    $closed -eq $true
) "fermeture incident correctement executee"

# 16
$closedList = @(Get-Alerts -TenantId "tenant-X" -Status "CLOSED")

Assert-Pass (
    $closedList.Count -eq 1 -and
    $closedList[0].Status -eq "CLOSED"
) "incident ferme correctement persiste"

# 17
$secretBlocked = $false

try {

    $bad = New-Alert `
        -Type "SECRET_TEST" `
        -Severity "WARNING" `
        -Message "api_token=password-secret" `
        -TenantId "tenant-S" `
        -ClientId "client-S" `
        -ProjectId "project-S" `
        -WorkerId "worker-S" `
        -Source "security"

    Write-Alert -Alert $bad | Out-Null
}
catch {
    $secretBlocked = $true
}

Assert-Pass $secretBlocked `
    "alerte contenant un secret correctement bloquee"

# 18
$invalid = $false

try {

    New-Alert `
        -Type "" `
        -Severity "WARNING" `
        -Message "bad" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -Source "test" | Out-Null
}
catch {
    $invalid = $true
}

Assert-Pass $invalid `
    "type d'alerte vide correctement bloque"

# 19
$invalidMessage = $false

try {

    New-Alert `
        -Type "BAD" `
        -Severity "WARNING" `
        -Message "" `
        -TenantId "tenant-A" `
        -ClientId "client-A" `
        -ProjectId "project-A" `
        -WorkerId "worker-A" `
        -Source "test" | Out-Null
}
catch {
    $invalidMessage = $true
}

Assert-Pass $invalidMessage `
    "message alerte vide correctement bloque"

# 20
$globalAlerts = @(Get-Alerts)

Assert-Pass (
    $globalAlerts.Count -eq 2
) "lecture globale des alertes correctement executee"

# 21
$criticalAlerts = @(Get-Alerts -Severity "CRITICAL")

Assert-Pass (
    $criticalAlerts.Count -eq 1
) "filtrage par severite correctement execute"

# 22
Reset-AlertState | Out-Null

Assert-Pass (
    @(Get-Alerts).Count -eq 0
) "reset des alertes correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-34" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Alerting & Incident Detection Manager operationnel." -ForegroundColor Green
    exit 0
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
    exit 1
}