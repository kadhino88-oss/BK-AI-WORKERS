$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-audit-retention"

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

$RetentionId   = "RET-7501"
$EventId       = "EV-7501"
$CorrelationId = "CORR-7501"
$DeliveryId    = "DEL-7501"
$ExecutionId   = "EXE-7501"
$TenantId      = "TEN-01"
$ClientId      = "CLI-01"
$ProjectId     = "PROJ-01"

$null = Reset-RecoveryAuditRetention

# 1
$cfg = Get-RecoveryAuditRetentionConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Retention guard enabled" (
    $cfg.retentionGuardEnabled -eq $true
)

# 3
Assert-Test "Immutability enabled" (
    $cfg.immutabilityEnabled -eq $true
)

# 4
Assert-Test "Deletion protection enabled" (
    $cfg.deletionProtectionEnabled -eq $true
)

# 5
$state = @(Get-RecoveryAuditRetentionRecords)

Assert-Test "Initial state empty" (
    $state.Length -eq 0
)

# 6
$valid = Test-RecoveryAuditRetentionContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Valid retention context accepted" (
    $valid.Success -eq $true
)

# 7
$missingRetentionId = Test-RecoveryAuditRetentionContext `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Missing RetentionId blocked" (
    $missingRetentionId.Reason -eq "RETENTION_ID_REQUIRED"
)

# 8
$missingEvent = Test-RecoveryAuditRetentionContext `
    -RetentionId $RetentionId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Missing EventId blocked" (
    $missingEvent.Reason -eq "EVENT_ID_REQUIRED"
)

# 9
$missingCorrelation = Test-RecoveryAuditRetentionContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Missing CorrelationId blocked" (
    $missingCorrelation.Reason -eq "CORRELATION_ID_REQUIRED"
)

# 10
$missingContext = Test-RecoveryAuditRetentionContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Incomplete context blocked" (
    $missingContext.Reason -eq "CONTEXT_INCOMPLETE"
)

# 11
$badStatus = Test-RecoveryAuditRetentionContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "INVALID"

Assert-Test "Invalid retention status blocked" (
    $badStatus.Reason -eq "RETENTION_STATUS_INVALID"
)

# 12
$registered = Register-RecoveryAuditRetention `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Retention registered" (
    $registered.Success -eq $true
)

# 13
Assert-Test "Record is immutable" (
    $registered.Immutable -eq $true
)

# 14
Assert-Test "Expiration generated" (
    -not [string]::IsNullOrWhiteSpace(
        [string]$registered.ExpiresAtUtc
    )
)

# 15
$loaded = Get-RecoveryAuditRetentionRecord `
    -RetentionId $RetentionId

Assert-Test "Retention record retrievable" (
    $null -ne $loaded
)

# 16
$retentionCheck = Test-RecoveryAuditRetention `
    -RetentionId $RetentionId `
    -ReferenceTime ([DateTime]::UtcNow)

Assert-Test "Retention currently active" (
    $retentionCheck.Success -eq $true -and
    $retentionCheck.Status -eq "RETAINED"
)

# 17
$future = ([DateTime]::UtcNow).AddDays(
    [double]$cfg.retentionDays + 1
)

$expiredCheck = Test-RecoveryAuditRetention `
    -RetentionId $RetentionId `
    -ReferenceTime $future

Assert-Test "Future expiration detected" (
    $expiredCheck.Success -eq $true -and
    $expiredCheck.Status -eq "EXPIRED"
)

# 18
$mutation = Test-RecoveryAuditMutation `
    -RetentionId $RetentionId `
    -RequestedStatus "MODIFIED"

Assert-Test "Immutable mutation blocked" (
    $mutation.Success -eq $false -and
    $mutation.Reason -eq "IMMUTABLE_RECORD_MUTATION_BLOCKED"
)

# 19
$unchanged = Test-RecoveryAuditMutation `
    -RetentionId $RetentionId `
    -RequestedStatus "ACTIVE"

Assert-Test "Unchanged immutable state accepted" (
    $unchanged.Success -eq $true -and
    $unchanged.Status -eq "UNCHANGED"
)

# 20
$delete = Test-RecoveryAuditDeletion `
    -RetentionId $RetentionId `
    -Expired $false

Assert-Test "Manual deletion blocked" (
    $delete.Success -eq $false -and
    $delete.Reason -eq "MANUAL_DELETE_DISABLED"
)

# 21
$deleteExpired = Test-RecoveryAuditDeletion `
    -RetentionId $RetentionId `
    -Expired $true

Assert-Test "Expired purge blocked by policy" (
    $deleteExpired.Success -eq $false -and
    $deleteExpired.Reason -eq "MANUAL_DELETE_DISABLED"
)

# 22
$duplicate = Register-RecoveryAuditRetention `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -RetentionStatus "ACTIVE"

Assert-Test "Duplicate retention blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# 23
$stored = @(Get-RecoveryAuditRetentionRecords)

Assert-Test "Exactly one retention record persisted" (
    $stored.Length -eq 1
)

# 24
$null = Reset-RecoveryAuditRetention

$empty = @(Get-RecoveryAuditRetentionRecords)

Assert-Test "Retention state reset" (
    $empty.Length -eq 0
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-75"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"