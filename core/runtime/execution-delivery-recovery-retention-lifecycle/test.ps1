$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-retention-lifecycle"

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

$RetentionId   = "RET-7601"
$EventId       = "EV-7601"
$CorrelationId = "CORR-7601"
$DeliveryId    = "DEL-7601"
$ExecutionId   = "EXE-7601"
$TenantId      = "TEN-01"
$ClientId      = "CLI-01"
$ProjectId     = "PROJ-01"

$null = Reset-RetentionLifecycle

# 1
$cfg = Get-RetentionLifecycleConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# 2
Assert-Test "Lifecycle guard enabled" (
    $cfg.lifecycleGuardEnabled -eq $true
)

# 3
Assert-Test "Expiration enforcement enabled" (
    $cfg.expirationEnforcementEnabled -eq $true
)

# 4
Assert-Test "Transition guard enabled" (
    $cfg.transitionGuardEnabled -eq $true
)

# 5
$state = @(Get-RetentionLifecycleRecords)

Assert-Test "Initial state empty" (
    $state.Length -eq 0
)

# 6
$valid = Test-RetentionLifecycleContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -State "ACTIVE"

Assert-Test "Valid context accepted" (
    $valid.Success -eq $true
)

# 7
$missingId = Test-RetentionLifecycleContext `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -State "ACTIVE"

Assert-Test "Missing RetentionId blocked" (
    $missingId.Reason -eq "RETENTION_ID_REQUIRED"
)

# 8
$missingContext = Test-RetentionLifecycleContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -State "ACTIVE"

Assert-Test "Incomplete context blocked" (
    $missingContext.Reason -eq "CONTEXT_INCOMPLETE"
)

# 9
$badState = Test-RetentionLifecycleContext `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -State "INVALID"

Assert-Test "Invalid state blocked" (
    $badState.Reason -eq "STATE_INVALID"
)

# 10
$initialized = Initialize-RetentionLifecycle `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Lifecycle initialized" (
    $initialized.Success -eq $true
)

# 11
Assert-Test "Initial state ACTIVE" (
    $initialized.CurrentState -eq "ACTIVE"
)

# 12
Assert-Test "Expiration generated" (
    -not [string]::IsNullOrWhiteSpace(
        [string]$initialized.ExpiresAtUtc
    )
)

# 13
$duplicateInit = Initialize-RetentionLifecycle `
    -RetentionId $RetentionId `
    -EventId $EventId `
    -CorrelationId $CorrelationId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId

Assert-Test "Duplicate initialization blocked" (
    $duplicateInit.Status -eq "DUPLICATE"
)

# 14
$toRetained = Invoke-RetentionLifecycleTransition `
    -RetentionId $RetentionId `
    -ToState "RETAINED"

Assert-Test "ACTIVE to RETAINED allowed" (
    $toRetained.Success -eq $true -and
    $toRetained.ToState -eq "RETAINED"
)

# 15
$record = Get-RetentionLifecycleRecord `
    -RetentionId $RetentionId

Assert-Test "RETAINED state persisted" (
    $record.CurrentState -eq "RETAINED"
)

# 16
$backward = Test-RetentionLifecycleTransition `
    -RetentionId $RetentionId `
    -FromState "RETAINED" `
    -ToState "ACTIVE"

Assert-Test "Backward transition blocked" (
    $backward.Reason -eq "BACKWARD_TRANSITION_BLOCKED"
)

# 17
$premature = Invoke-RetentionLifecycleTransition `
    -RetentionId $RetentionId `
    -ToState "EXPIRED" `
    -ReferenceTime ([DateTime]::UtcNow)

Assert-Test "Premature expiration blocked" (
    $premature.Reason -eq "RETENTION_NOT_EXPIRED"
)

# 18
$future = ([DateTime]::UtcNow).AddDays(
    [double]$cfg.retentionDays + 1
)

$expirationDue = Test-RetentionExpirationEnforcement `
    -RetentionId $RetentionId `
    -ReferenceTime $future

Assert-Test "Expiration due detected" (
    $expirationDue.Success -eq $true -and
    $expirationDue.Status -eq "EXPIRATION_DUE"
)

# 19
$expire = Invoke-RetentionLifecycleTransition `
    -RetentionId $RetentionId `
    -ToState "EXPIRED" `
    -ReferenceTime $future

Assert-Test "RETAINED to EXPIRED allowed after expiry" (
    $expire.Success -eq $true -and
    $expire.ToState -eq "EXPIRED"
)

# 20
$expiredRecord = Get-RetentionLifecycleRecord `
    -RetentionId $RetentionId

Assert-Test "EXPIRED state persisted" (
    $expiredRecord.CurrentState -eq "EXPIRED"
)

# 21
$reopen = Test-RetentionLifecycleTransition `
    -RetentionId $RetentionId `
    -FromState "EXPIRED" `
    -ToState "RETAINED"

Assert-Test "Expired state cannot reopen" (
    $reopen.Reason -eq "EXPIRED_STATE_TERMINAL"
)

# 22
$expiredCheck = Test-RetentionExpirationEnforcement `
    -RetentionId $RetentionId `
    -ReferenceTime $future

Assert-Test "Expired state enforced" (
    $expiredCheck.Success -eq $true -and
    $expiredCheck.Status -eq "EXPIRED"
)

# 23
$records = @(Get-RetentionLifecycleRecords)

Assert-Test "Exactly one lifecycle record persisted" (
    $records.Length -eq 1 -and
    $records[0].RetentionId -eq $RetentionId
)

# 24
$null = Reset-RetentionLifecycle

$empty = @(Get-RetentionLifecycleRecords)

Assert-Test "Lifecycle state reset" (
    $empty.Length -eq 0
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-76"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"