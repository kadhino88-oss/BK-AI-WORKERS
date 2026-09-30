$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-audit-integrity"

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

$CorrelationId   = "CORR-7401"
$DeliveryId      = "DEL-7401"
$ExecutionId     = "EXE-7401"
$TenantId        = "TEN-01"
$ClientId        = "CLI-01"
$ProjectId       = "PROJ-01"
$RecoveryId      = "REC-01"
$AuthorizationId = "AUTH-01"
$FinalizationId  = "FIN-01"
$ClosureId       = "CLOSE-01"

$null = Reset-RecoveryAuditIntegrity

# 1
$cfg = Get-RecoveryAuditIntegrityConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Integrity guard enabled" (
    $cfg.integrityGuardEnabled -eq $true
)

# 3
Assert-Test "Hash chain enabled" (
    $cfg.hashChainEnabled -eq $true
)

# 4
Assert-Test "Tamper detection enabled" (
    $cfg.tamperDetectionEnabled -eq $true
)

# 5
$state = @(Get-RecoveryAuditIntegrityEvents)

Assert-Test "Initial state empty" (
    $state.Length -eq 0
)

# 6
$context = Test-RecoveryAuditIntegrityContext `
    -EventId "EV-7401-01" `
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

Assert-Test "Valid context accepted" (
    $context.Success -eq $true
)

# 7
$missingCorrelation = Test-RecoveryAuditIntegrityContext `
    -EventId "EV-7401-X" `
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
    -EventType "TEST"

Assert-Test "Missing correlation blocked" (
    $missingCorrelation.Reason -eq "CORRELATION_ID_REQUIRED"
)

# 8
$missingContext = Test-RecoveryAuditIntegrityContext `
    -EventId "EV-7401-X" `
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
    -EventType "TEST"

Assert-Test "Incomplete context blocked" (
    $missingContext.Reason -eq "CONTEXT_INCOMPLETE"
)

# 9
$missingEvent = Test-RecoveryAuditIntegrityContext `
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
    -EventType "TEST"

Assert-Test "Missing EventId blocked" (
    $missingEvent.Reason -eq "EVENT_ID_REQUIRED"
)

# 10
$e1 = Add-RecoveryAuditIntegrityEvent `
    -EventId "EV-7401-01" `
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

Assert-Test "First event recorded" (
    $e1.Success -eq $true
)

# 11
Assert-Test "First sequence equals one" (
    [int]$e1.Sequence -eq 1
)

# 12
Assert-Test "First previous hash empty" (
    [string]::IsNullOrEmpty([string]$e1.PreviousHash)
)

# 13
Assert-Test "First event hash generated" (
    -not [string]::IsNullOrWhiteSpace([string]$e1.EventHash)
)

# 14
$e2 = Add-RecoveryAuditIntegrityEvent `
    -EventId "EV-7401-02" `
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

Assert-Test "Second event recorded" (
    $e2.Success -eq $true
)

# 15
Assert-Test "Second sequence equals two" (
    [int]$e2.Sequence -eq 2
)

# 16
Assert-Test "Second previous hash links to first" (
    [string]$e2.PreviousHash -eq [string]$e1.EventHash
)

# 17
$e3 = Add-RecoveryAuditIntegrityEvent `
    -EventId "EV-7401-03" `
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

Assert-Test "Third event recorded" (
    $e3.Success -eq $true
)

# 18
$e4 = Add-RecoveryAuditIntegrityEvent `
    -EventId "EV-7401-04" `
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

Assert-Test "Fourth event recorded" (
    $e4.Success -eq $true
)

# 19
$e5 = Add-RecoveryAuditIntegrityEvent `
    -EventId "EV-7401-05" `
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

Assert-Test "Fifth event recorded" (
    $e5.Success -eq $true
)

# 20
$trace = Test-RecoveryAuditIntegrityChain `
    -CorrelationId $CorrelationId

Assert-Test "Complete hash chain valid" (
    $trace.Success -eq $true
)

# 21
Assert-Test "Trace contains five events" (
    [int]$trace.EventCount -eq 5
)

# 22
$duplicate = Add-RecoveryAuditIntegrityEvent `
    -EventId "EV-7401-05" `
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

Assert-Test "Duplicate EventId blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# 23
$stateBeforeTamper = @(Get-RecoveryAuditIntegrityEvents)

$target = $null

foreach ($event in $stateBeforeTamper) {
    if ($event.EventId -eq "EV-7401-03") {
        $target = $event
        break
    }
}

$target.LifecycleState = "TAMPERED"

$null = Save-RecoveryAuditIntegrityEvents $stateBeforeTamper

$tamperCheck = Test-RecoveryAuditIntegrityChain `
    -CorrelationId $CorrelationId

Assert-Test "Tampering detected" (
    $tamperCheck.Success -eq $false -and
    $tamperCheck.Reason -eq "EVENT_HASH_MISMATCH"
)

# 24
$null = Reset-RecoveryAuditIntegrity

$empty = @(Get-RecoveryAuditIntegrityEvents)

Assert-Test "Reset clears integrity state" (
    $empty.Length -eq 0
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-74"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"