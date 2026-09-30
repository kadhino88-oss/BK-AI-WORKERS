$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-audit"

. (Join-Path $Dir "runtime.ps1")

$Pass = 0
$Fail = 0

function Assert-Test {
    param(
        [string]$Name,
        [bool]$Condition
    )

    if ($Condition) {
        Write-Host "[PASS] $Name"
        $script:Pass++
    }
    else {
        Write-Host "[FAIL] $Name"
        $script:Fail++
    }
}

$CorrelationId   = "CORR-7301"
$DeliveryId      = "DEL-7301"
$ExecutionId     = "EXE-7301"
$TenantId        = "TEN-01"
$ClientId        = "CLI-01"
$ProjectId       = "PROJ-01"
$RecoveryId      = "REC-01"
$AuthorizationId = "AUTH-01"
$FinalizationId  = "FIN-01"
$ClosureId       = "CLOSURE-01"

$null = Reset-RecoveryAudit

# ============================================================
# 1
# ============================================================

$cfg = Get-RecoveryAuditConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# ============================================================
# 2
# ============================================================

Assert-Test "Audit guard enabled" (
    $cfg.auditGuardEnabled -eq $true
)

# ============================================================
# 3
# ============================================================

Assert-Test "Trace guard enabled" (
    $cfg.traceGuardEnabled -eq $true
)

# ============================================================
# 4
# ============================================================

$state = @(Get-RecoveryAuditEvents)

Assert-Test "Initial audit state empty" (
    $state.Count -eq 0
)

# ============================================================
# 5
# ============================================================

$valid = Test-RecoveryAuditTrace `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "AUTHORIZED" `
    -EventType "RECOVERY_AUTHORIZED"

Assert-Test "Valid audit context accepted" (
    $valid.Success -eq $true
)

# ============================================================
# 6
# ============================================================

$missingCorrelation = Test-RecoveryAuditTrace `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "AUTHORIZED" `
    -EventType "RECOVERY_AUTHORIZED"

Assert-Test "Missing correlation blocked" (
    $missingCorrelation.Reason -eq "CORRELATION_ID_REQUIRED"
)

# ============================================================
# 7
# ============================================================

$missingContext = Test-RecoveryAuditTrace `
    -CorrelationId $CorrelationId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "AUTHORIZED" `
    -EventType "RECOVERY_AUTHORIZED"

Assert-Test "Incomplete context blocked" (
    $missingContext.Reason -eq "CONTEXT_INCOMPLETE"
)

# ============================================================
# 8
# ============================================================

$missingRecovery = Test-RecoveryAuditTrace `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "AUTHORIZED" `
    -EventType "RECOVERY_AUTHORIZED"

Assert-Test "Missing RecoveryId blocked" (
    $missingRecovery.Reason -eq "RECOVERY_ID_REQUIRED"
)

# ============================================================
# 9
# ============================================================

$badState = Test-RecoveryAuditTrace `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "OPEN" `
    -EventType "RECOVERY_AUTHORIZED"

Assert-Test "Invalid lifecycle blocked" (
    $badState.Reason -eq "LIFECYCLE_STATE_INVALID"
)

# ============================================================
# 10
# ============================================================

$missingEventType = Test-RecoveryAuditTrace `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "AUTHORIZED"

Assert-Test "Missing event type blocked" (
    $missingEventType.Reason -eq "EVENT_TYPE_REQUIRED"
)

# ============================================================
# 11
# ============================================================

$e1 = Add-RecoveryAuditEvent `
    -EventId "EV-7301-01" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "AUTHORIZED" `
    -EventType "RECOVERY_AUTHORIZED"

Assert-Test "Authorized event recorded" (
    $e1.Success -eq $true
)

# ============================================================
# 12
# ============================================================

$e2 = Add-RecoveryAuditEvent `
    -EventId "EV-7301-02" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "RECOVERING" `
    -EventType "RECOVERY_STARTED"

Assert-Test "Recovering event recorded" (
    $e2.Success -eq $true
)

# ============================================================
# 13
# ============================================================

$e3 = Add-RecoveryAuditEvent `
    -EventId "EV-7301-03" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "CONSISTENT" `
    -EventType "RECOVERY_CONSISTENT"

Assert-Test "Consistency event recorded" (
    $e3.Success -eq $true
)

# ============================================================
# 14
# ============================================================

$e4 = Add-RecoveryAuditEvent `
    -EventId "EV-7301-04" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "FINALIZED" `
    -EventType "RECOVERY_FINALIZED"

Assert-Test "Finalized event recorded" (
    $e4.Success -eq $true
)

# ============================================================
# 15
# ============================================================

$e5 = Add-RecoveryAuditEvent `
    -EventId "EV-7301-05" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "CLOSED" `
    -EventType "RECOVERY_CLOSED"

Assert-Test "Closed event recorded" (
    $e5.Success -eq $true
)

# ============================================================
# 16
# ============================================================

$events = @(Get-RecoveryAuditEvents)

Assert-Test "Five lifecycle events persisted" (
    $events.Count -eq 5
)

# ============================================================
# 17
# ============================================================

$first = Get-RecoveryAuditEvent -EventId "EV-7301-01"

Assert-Test "First event retrievable" (
    ($null -ne $first) -and
    ($first.LifecycleState -eq "AUTHORIZED")
)

# ============================================================
# 18
# ============================================================

$correlated = @(Get-RecoveryAuditCorrelation -CorrelationId $CorrelationId)

Assert-Test "Correlation returns all events" (
    $correlated.Count -eq 5
)

# ============================================================
# 19
# ============================================================

Assert-Test "Sequence starts at one" (
    [int]$correlated[0].Sequence -eq 1
)

# ============================================================
# 20
# ============================================================

$duplicate = Add-RecoveryAuditEvent `
    -EventId "EV-7301-05" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -ClosureId $ClosureId `
    -LifecycleState "CLOSED" `
    -EventType "RECOVERY_CLOSED"

Assert-Test "Duplicate event blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# ============================================================
# 21
# ============================================================

$trace = Test-RecoveryLifecycleTrace `
    -CorrelationId $CorrelationId

Assert-Test "Complete lifecycle trace valid" (
    $trace.Success -eq $true
)

# ============================================================
# 22
# ============================================================

$traceMissing = Test-RecoveryLifecycleTrace `
    -CorrelationId "UNKNOWN-CORRELATION"

Assert-Test "Unknown trace blocked" (
    $traceMissing.Reason -eq "TRACE_NOT_FOUND"
)

# ============================================================
# 23
# ============================================================

$correlatedExecution = @(
    $correlated | Where-Object {
        $_.ExecutionId -eq $ExecutionId
    }
)

Assert-Test "Execution correlation preserved" (
    $correlatedExecution.Count -eq 5
)

# ============================================================
# 24
# ============================================================

$allContextOk = $true

foreach ($event in $correlated) {

    if ($event.DeliveryId -ne $DeliveryId) {
        $allContextOk = $false
    }

    if ($event.ExecutionId -ne $ExecutionId) {
        $allContextOk = $false
    }

    if ($event.TenantId -ne $TenantId) {
        $allContextOk = $false
    }

    if ($event.ClientId -ne $ClientId) {
        $allContextOk = $false
    }

    if ($event.ProjectId -ne $ProjectId) {
        $allContextOk = $false
    }

    if ($event.RecoveryId -ne $RecoveryId) {
        $allContextOk = $false
    }

    if ($event.AuthorizationId -ne $AuthorizationId) {
        $allContextOk = $false
    }

    if ($event.FinalizationId -ne $FinalizationId) {
        $allContextOk = $false
    }

    if ($event.ClosureId -ne $ClosureId) {
        $allContextOk = $false
    }
}

Assert-Test "All lifecycle events preserve context" (
    $allContextOk
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-73"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"