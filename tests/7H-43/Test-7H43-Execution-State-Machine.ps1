$ErrorActionPreference = "Stop"

$Runtime = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-state-machine\EXECUTION-STATE-MACHINE-RUNTIME.ps1"
$StatePath = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-state-machine\state\state-machine.json"

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

Reset-StateMachineState | Out-Null

# 1
$config = Get-StateMachineConfig

Assert-Pass (
    $config.version -eq "1.0" -and
    $config.system -eq "BK-AI-WORKERS" -and
    $config.enabled -eq $true
) "configuration State Machine valide"

# 2
Assert-Pass (
    $config.stateMachineEnabled -eq $true -and
    $config.transitionGuardsEnabled -eq $true -and
    $config.strictMode -eq $true
) "state machine et guards actifs"

# 3
Assert-Pass (
    $config.captureSecrets -eq $false -and
    $config.capturePayloads -eq $false -and
    $config.liveExecutionEnabled -eq $false
) "securite et LIVE correctement verrouilles"

# 4
$allowed = Test-StateTransition `
    -FromState "CREATED" `
    -ToState "QUEUED"

Assert-Pass (
    $allowed -eq $true
) "transition CREATED vers QUEUED autorisee"

# 5
$forbidden = Test-StateTransition `
    -FromState "CREATED" `
    -ToState "COMPLETED"

Assert-Pass (
    $forbidden -eq $false
) "transition CREATED vers COMPLETED interdite"

# 6
$register = Register-Execution `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A"

Assert-Pass (
    $register.Registered -eq $true -and
    $register.State -eq "CREATED"
) "execution correctement enregistree"

# 7
$duplicate = Register-Execution `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ClientId "client-A" `
    -ProjectId "project-A" `
    -WorkerId "worker-A"

Assert-Pass (
    $duplicate.Registered -eq $false
) "execution duplicate correctement bloquee"

# 8
$queued = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ToState "QUEUED"

Assert-Pass (
    $queued.Transitioned -eq $true -and
    $queued.ToState -eq "QUEUED" -and
    $queued.Version -eq 2
) "transition QUEUED correctement executee"

# 9
$running = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ToState "RUNNING"

Assert-Pass (
    $running.Transitioned -eq $true -and
    $running.ToState -eq "RUNNING"
) "transition RUNNING correctement executee"

# 10
$paused = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ToState "PAUSED"

Assert-Pass (
    $paused.Transitioned -eq $true -and
    $paused.ToState -eq "PAUSED"
) "transition PAUSED correctement executee"

# 11
$resume = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ToState "RUNNING"

Assert-Pass (
    $resume.Transitioned -eq $true -and
    $resume.ToState -eq "RUNNING"
) "reprise RUNNING correctement executee"

# 12
$completed = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ToState "COMPLETED"

Assert-Pass (
    $completed.Transitioned -eq $true -and
    $completed.ToState -eq "COMPLETED"
) "transition COMPLETED correctement executee"

# 13
$invalidAfterCompletion = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A" `
    -ToState "RUNNING"

Assert-Pass (
    $invalidAfterCompletion.Transitioned -eq $false
) "reprise depuis COMPLETED correctement bloquee"

# 14
$wrongTenant = Transition-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-B" `
    -ToState "FAILED"

Assert-Pass (
    $wrongTenant.Transitioned -eq $false
) "transition cross-tenant correctement bloquee"

# 15
$exec2 = Register-Execution `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ClientId "client-B" `
    -ProjectId "project-B" `
    -WorkerId "worker-B"

Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "QUEUED" | Out-Null

Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "RUNNING" | Out-Null

$failed = Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "FAILED"

Assert-Pass (
    $failed.Transitioned -eq $true -and
    $failed.ToState -eq "FAILED"
) "transition FAILED correctement executee"

# 16
$retry = Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "QUEUED"

Assert-Pass (
    $retry.Transitioned -eq $true -and
    $retry.ToState -eq "QUEUED"
) "retry depuis FAILED correctement autorise"

# 17
$sameState = Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "QUEUED"

Assert-Pass (
    $sameState.Transitioned -eq $false
) "transition vers le meme etat correctement bloquee"

# 18
$missing = Transition-ExecutionState `
    -ExecutionId "unknown-exec" `
    -TenantId "tenant-A" `
    -ToState "RUNNING"

Assert-Pass (
    $missing.Transitioned -eq $false
) "execution inconnue correctement bloquee"

# 19
$history = @(Get-StateHistory `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A")

Assert-Pass (
    $history.Count -eq 1 -and
    $history[0].CurrentState -eq "COMPLETED"
) "etat courant correctement restitue"

# 20
$current = Get-ExecutionState `
    -ExecutionId "exec-001" `
    -TenantId "tenant-A"

Assert-Pass (
    $current.State -eq "COMPLETED" -and
    $current.Version -ge 5
) "version d'etat correctement maintenue"

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
) "state machine sans secret"

# 22
$cancel = Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "CANCELLED"

Assert-Pass (
    $cancel.Transitioned -eq $true -and
    $cancel.ToState -eq "CANCELLED"
) "transition CANCELLED correctement executee"

# 23
$restartCancelled = Transition-ExecutionState `
    -ExecutionId "exec-002" `
    -TenantId "tenant-B" `
    -ToState "RUNNING"

Assert-Pass (
    $restartCancelled.Transitioned -eq $false
) "reprise depuis CANCELLED correctement bloquee"

# 24
Reset-StateMachineState | Out-Null

Assert-Pass (
    $null -eq (Get-ExecutionState `
        -ExecutionId "exec-001")
) "reset State Machine correctement execute"

Write-Host ""
Write-Host "RESULTATS 7H-43" -ForegroundColor Cyan
Write-Host "PASS : $pass"
Write-Host "FAIL : $fail"

if ($fail -eq 0) {

    Write-Host ""
    Write-Host "RESULTAT FINAL : PASS" -ForegroundColor Green
    Write-Host "Execution State Machine & Transition Guard Manager operationnel." -ForegroundColor Green
}
else {

    Write-Host ""
    Write-Host "RESULTAT FINAL : FAIL" -ForegroundColor Red
}

Read-Host "Appuyez sur ENTREE pour rester dans PowerShell"