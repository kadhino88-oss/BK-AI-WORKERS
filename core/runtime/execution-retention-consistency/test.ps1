$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-retention-consistency"

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

$ConsistencyId  = "CONS-7701"
$RetentionId    = "RET-7701"
$EventId        = "EV-7701"
$CorrelationId  = "CORR-7701"
$DeliveryId     = "DEL-7701"
$ExecutionId    = "EXE-7701"
$TenantId       = "TEN-01"
$ClientId       = "CLI-01"
$ProjectId      = "PROJ-01"

$null = Reset-RetentionConsistency

# 1
$cfg = Get-RetentionConsistencyConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Consistency guard enabled" (
    $cfg.consistencyGuardEnabled -eq $true
)

# 3
Assert-Test "Audit link guard enabled" (
    $cfg.auditLinkGuardEnabled -eq $true
)

# 4
Assert-Test "Context isolation enabled" (
    $cfg.contextIsolationEnabled -eq $true
)

# 5
$state = @(Get-RetentionConsistencyRecords)

Assert-Test "Initial state empty" (
    $state.Length -eq 0
)

# 6
$valid = Test-RetentionConsistencyContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Valid context accepted" (
    $valid.Success -eq $true
)

# 7
$missingRetention = Test-RetentionConsistencyContext `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Missing RetentionId blocked" (
    $missingRetention.Reason -eq "RETENTION_ID_REQUIRED"
)

# 8
$missingEvent = Test-RetentionConsistencyContext `
    -RetentionId $RetentionId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Missing EventId blocked" (
    $missingEvent.Reason -eq "EVENT_ID_REQUIRED"
)

# 9
$missingCorrelation = Test-RetentionConsistencyContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Missing CorrelationId blocked" (
    $missingCorrelation.Reason -eq "CORRELATION_ID_REQUIRED"
)

# 10
$missingContext = Test-RetentionConsistencyContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Incomplete context blocked" (
    $missingContext.Reason -eq "CONTEXT_INCOMPLETE"
)

# 11
$badState = Test-RetentionConsistencyContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "INVALID"

Assert-Test "Invalid lifecycle state blocked" (
    $badState.Reason -eq "LIFECYCLE_STATE_INVALID"
)

# 12
$registered = Register-RetentionConsistency `
    -ConsistencyId $ConsistencyId `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Consistency record registered" (
    $registered.Success -eq $true
)

# 13
Assert-Test "Registered status CONSISTENT" (
    $registered.Status -eq "REGISTERED"
)

# 14
$stored = Get-RetentionConsistencyRecord `
    -ConsistencyId $ConsistencyId

Assert-Test "Consistency record retrievable" (
    $null -ne $stored
)

# 15
Assert-Test "Retention link preserved" (
    $stored.RetentionId -eq $RetentionId
)

# 16
Assert-Test "Event link preserved" (
    $stored.EventId -eq $EventId
)

# 17
Assert-Test "Correlation link preserved" (
    $stored.CorrelationId -eq $CorrelationId
)

# 18
$validLink = Test-RetentionConsistencyLink `
    -ConsistencyId $ConsistencyId `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Valid audit link accepted" (
    $validLink.Success -eq $true
)

# 19
$mismatchTenant = Test-RetentionConsistencyLink `
    -ConsistencyId $ConsistencyId `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId "TEN-TAMPERED" `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Cross-tenant mismatch blocked" (
    $mismatchTenant.Reason -eq "AUDIT_LINK_MISMATCH"
)

# 20
$mismatchEvent = Test-RetentionConsistencyLink `
    -ConsistencyId $ConsistencyId `
    -RetentionId $RetentionId `
    -EventId "EV-TAMPERED" `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Event mismatch blocked" (
    $mismatchEvent.Reason -eq "AUDIT_LINK_MISMATCH"
)

# 21
$mismatchProject = Test-RetentionConsistencyLink `
    -ConsistencyId $ConsistencyId `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId "PROJ-TAMPERED"

Assert-Test "Project mismatch blocked" (
    $mismatchProject.Reason -eq "AUDIT_LINK_MISMATCH"
)

# 22
$duplicate = Register-RetentionConsistency `
    -ConsistencyId "CONS-7702" `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LifecycleState "ACTIVE"

Assert-Test "Duplicate retention link blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# 23
$records = @(Get-RetentionConsistencyRecords)

Assert-Test "Exactly one consistency record persisted" (
    $records.Length -eq 1
)

# 24
$null = Reset-RetentionConsistency

$empty = @(Get-RetentionConsistencyRecords)

Assert-Test "Consistency state reset" (
    $empty.Length -eq 0
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-77"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"