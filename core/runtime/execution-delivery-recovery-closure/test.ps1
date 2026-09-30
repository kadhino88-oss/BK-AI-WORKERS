$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Dir  = Join-Path $Root "core\runtime\execution-delivery-recovery-closure"

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

# ------------------------------------------------------------
# CONTEXTE DE BASE
# ------------------------------------------------------------

$DeliveryId      = "DEL-7101"
$ExecutionId     = "EXE-7101"
$TenantId        = "TEN-01"
$ClientId        = "CLI-01"
$ProjectId       = "PROJ-01"
$LeaseId         = "LEASE-01"
$RecoveryId      = "REC-01"
$AuthorizationId = "AUTH-01"
$FinalizationId  = "FIN-01"

$null = Reset-RecoveryClosures

# 1
$cfg = Get-RecoveryClosureConfig
Assert-Test "Config loaded" ($null -ne $cfg)

# 2
Assert-Test "Closure guard enabled" (
    $cfg.closureGuardEnabled -eq $true
)

# 3
$state = Get-RecoveryClosureState
Assert-Test "Initial state empty" (
    $state.Count -eq 0
)

# 4
$allowed = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Valid lifecycle allowed" (
    $allowed.Success -eq $true
)

# 5
Assert-Test "Valid lifecycle status" (
    $allowed.Status -eq "AUTHORIZED"
)

# 6
$missingDelivery = Test-RecoveryClosureConsistency `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Missing DeliveryId blocked" (
    $missingDelivery.Reason -eq "CONTEXT_INCOMPLETE"
)

# 7
$missingRecovery = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Missing RecoveryId blocked" (
    $missingRecovery.Reason -eq "RECOVERY_ID_REQUIRED"
)

# 8
$unauthorized = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "BLOCKED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Unauthorized recovery blocked" (
    $unauthorized.Reason -eq "RECOVERY_NOT_AUTHORIZED"
)

# 9
$inconsistent = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "INCONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Inconsistent recovery blocked" (
    $inconsistent.Reason -eq "RECOVERY_INCONSISTENT"
)

# 10
$notFinalized = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "PENDING" `
    -FinalizationId $FinalizationId

Assert-Test "Non-finalized recovery blocked" (
    $notFinalized.Reason -eq "FINALIZATION_REQUIRED"
)

# 11
$missingFinalizationId = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED"

Assert-Test "Missing FinalizationId blocked" (
    $missingFinalizationId.Reason -eq "FINALIZATION_ID_REQUIRED"
)

# 12
$badRecoveryState = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "FAILED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Invalid recovery state blocked" (
    $badRecoveryState.Reason -eq "RECOVERY_STATE_INVALID"
)

# 13
$missingAuth = Test-RecoveryClosureConsistency `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Missing AuthorizationId blocked" (
    $missingAuth.Reason -eq "AUTHORIZATION_ID_REQUIRED"
)

# 14
$closed = Close-DeliveryRecovery `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Closure succeeds" (
    $closed.Success -eq $true
)

# 15
Assert-Test "Closure status is CLOSED" (
    $closed.Status -eq "CLOSED"
)

# 16
Assert-Test "Closure reason correct" (
    $closed.Reason -eq "RECOVERY_CLOSED"
)

# 17
Assert-Test "Delivery preserved" (
    $closed.DeliveryId -eq $DeliveryId
)

# 18
Assert-Test "Execution preserved" (
    $closed.ExecutionId -eq $ExecutionId
)

# 19
Assert-Test "Tenant preserved" (
    $closed.TenantId -eq $TenantId
)

# 20
Assert-Test "Client preserved" (
    $closed.ClientId -eq $ClientId
)

# 21
Assert-Test "Project preserved" (
    $closed.ProjectId -eq $ProjectId
)

# 22
Assert-Test "Finalization link preserved" (
    $closed.FinalizationId -eq $FinalizationId
)

# 23
$duplicate = Close-DeliveryRecovery `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT" `
    -FinalizationState "FINALIZED" `
    -FinalizationId $FinalizationId

Assert-Test "Duplicate closure blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# 24
$stored = Get-RecoveryClosureState
$found = $null

foreach ($entry in $stored) {
    if ($entry.ClosureId -eq $closed.ClosureId) {
        $found = $entry
        break
    }
}

Assert-Test "Closure persisted and retrievable" (
    ($null -ne $found) -and
    ($found.Status -eq "CLOSED") -and
    ($found.RecoveryId -eq $RecoveryId) -and
    ($found.FinalizationId -eq $FinalizationId)
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-71"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"