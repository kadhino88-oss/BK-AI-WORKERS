$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-deadline-sla\EXECUTION-DEADLINE-SLA-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-deadline-sla\state\deadlines.json"

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

Reset-DeadlineState | Out-Null

# 1
$config = Get-DeadlineSlaConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration Deadline/SLA valide"

# 2
Assert-Pass (
    $config.deadlineManagerEnabled -eq $true -and
    $config.slaEnabled -eq $true -and
    $config.escalationEnabled -eq $true
) "deadline SLA et escalade actives"

# 3
Assert-Pass (
    $config.defaultSlaSeconds -eq 300 -and
    $config.warningRatio -eq 0.8
) "parametres SLA correctement configures"

# 4
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 5
$deadline = New-ExecutionDeadline `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A" `
    -SlaSeconds 300

Assert-Pass (
    $deadline.ExecutionId -eq "exec-001" -and
    $deadline.SlaSeconds -eq 300 -and
    $deadline.Status -eq "ACTIVE"
) "deadline correctement generee"

# 6
$saved = Save-ExecutionDeadline -Deadline $deadline

Assert-Pass (
    $saved -eq $true
) "deadline correctement persistee"

# 7
$loaded = Get-ExecutionDeadline `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $null -ne $loaded -and
    $loaded.TenantId -eq "tenant-A"
) "deadline correctement relue"

# 8
$onTime = Test-DeadlineStatus `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $onTime.Status -eq "ON_TIME" -and
    $onTime.Warning -eq $false
) "execution dans les delais correctement detectee"

# 9
$warningSet = Set-DeadlineForTesting `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -SecondsFromNow 1

Assert-Pass (
    $warningSet -eq $true
) "deadline de test correctement modifiee"

# 10
Start-Sleep -Milliseconds 250

$warning = Test-DeadlineStatus `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $warning.Status -in @("WARNING","EXPIRED")
) "proximite deadline correctement detectee"

# 11
$warningMarked = Mark-DeadlineWarning `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $warningMarked -eq $true
) "warning SLA correctement marque"

# 12
$forcedExpired = Set-DeadlineForTesting `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -SecondsFromNow (-1)

Assert-Pass (
    $forcedExpired -eq $true
) "deadline expiree de test correctement definie"

# 13
$expired = Test-DeadlineStatus `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $expired.Status -eq "EXPIRED" -and
    $expired.EscalationRequired -eq $true
) "expiration SLA correctement detectee"

# 14
$escalated = Escalate-Deadline `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $escalated -eq $true
) "escalade SLA correctement executee"

# 15
$afterEscalation = Get-ExecutionDeadline `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    -not [string]::IsNullOrWhiteSpace(
        [string]$afterEscalation.EscalatedAtUtc
    )
) "escalade correctement persistee"

# 16
$completed = Complete-ExecutionDeadline `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $completed -eq $true
) "completion SLA correctement executee"

# 17
$completedStatus = Test-DeadlineStatus `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $completedStatus.Status -eq "COMPLETED"
) "execution completee correctement reconnue"

# 18
$crossTenant = Get-ExecutionDeadline `
    -ExecutionId "exec-001" `
    -TenantId "tenant-B"

Assert-Pass (
    $null -eq $crossTenant
) "lecture cross-tenant correctement bloquee"

# 19
$deadlineB = New-ExecutionDeadline `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B" `
    -SlaSeconds 100

Save-ExecutionDeadline -Deadline $deadlineB | Out-Null

Assert-Pass (
    $null -ne (
        Get-ExecutionDeadline `
            -ExecutionId "exec-002" `
            -TenantId "tenant-B"
    )
) "deuxieme tenant correctement gere"

# 20
$badExecution = $false

try {
    New-ExecutionDeadline `
        -ExecutionId "" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -SlaSeconds 100 | Out-Null
}
catch {
    $badExecution = $true
}

Assert-Pass $badExecution `
    "execution id vide correctement bloquee"

# 21
$badSla = $false

try {
    New-ExecutionDeadline `
        -ExecutionId "exec-bad" `
        -TenantId "tenant-X" `
        -ClientId "client-X" `
        -ProjectId "project-X" `
        -WorkerId "worker-X" `
        -SlaSeconds (-10) | Out-Null
}
catch {
    $badSla = $true
}

Assert-Pass $badSla `
    "SLA negative correctement bloquee"

# 22
$raw = ""

if (Test-Path -LiteralPath $StatePath) {

    $raw = Get-Content `
        -LiteralPath $StatePath `
        -Raw `
        -Encoding UTF8
}

Assert-Pass (
    $raw -notmatch '(?i)(password|passwd|secret|token|api[_-]?key|authorization|credential|private[_-]?key)'
) "etat Deadline/SLA sans secret"

# 23
$unknownStatus = Test-DeadlineStatus `
    -ExecutionId "unknown-execution" `
    -TenantId "tenant-A"

Assert-Pass (
    $unknownStatus.Status -eq "UNKNOWN"
) "execution inconnue correctement geree"

# 24
Reset-DeadlineState | Out-Null

Assert-Pass (
    $null -eq (
        Get-ExecutionDeadline `
            -ExecutionId "exec-001"
    )
) "reset Deadline/SLA correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-45" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution Deadline & SLA Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"