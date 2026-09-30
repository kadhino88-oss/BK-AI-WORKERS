$ErrorActionPreference = "Stop"

$Root = "C:\Users\FEUCOM\BK-AI-WORKERS"
$Dir  = Join-Path $Root "core\runtime\execution-delivery-recovery-finalization"

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

# BASE CONTEXT
$DeliveryId = "DEL-7001"
$ExecutionId = "EXE-7001"
$TenantId = "TEN-01"
$ClientId = "CLI-01"
$ProjectId = "PROJ-01"
$LeaseId = "LEASE-01"
$RecoveryId = "REC-01"
$AuthorizationId = "AUTH-01"

$null = Reset-RecoveryFinalization

# 1
$cfg = Get-RecoveryFinalizationConfig
Assert-Test "Config loaded" ($null -ne $cfg)

# 2
Assert-Test "Finalization enabled" ($cfg.finalizationEnabled -eq $true)

# 3
$state = Get-RecoveryFinalizationState
Assert-Test "Initial state empty" ($state.Count -eq 0)

# 4
$ok = Test-RecoveryFinalization `
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
    -ConsistencyState "CONSISTENT"

Assert-Test "Valid context allowed" ($ok.Success -eq $true)

# 5
Assert-Test "Valid status authorized" ($ok.Status -eq "AUTHORIZED")

# 6
$missing = Test-RecoveryFinalization `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT"

Assert-Test "Missing DeliveryId blocked" ($missing.Status -eq "BLOCKED")

# 7
$noRecovery = Test-RecoveryFinalization `
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
    -ConsistencyState "CONSISTENT"

Assert-Test "Recovery not ready blocked" ($noRecovery.Reason -eq "RECOVERY_NOT_READY")

# 8
$noAuth = Test-RecoveryFinalization `
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
    -ConsistencyState "CONSISTENT"

Assert-Test "Unauthorized recovery blocked" ($noAuth.Reason -eq "RECOVERY_NOT_AUTHORIZED")

# 9
$noConsistency = Test-RecoveryFinalization `
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
    -ConsistencyState "INCONSISTENT"

Assert-Test "Inconsistent recovery blocked" ($noConsistency.Reason -eq "RECOVERY_INCONSISTENT")

# 10
$noRecoveryId = Test-RecoveryFinalization `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -AuthorizationId $AuthorizationId `
    -RecoveryState "RECOVERED" `
    -AuthorizationState "AUTHORIZED" `
    -ConsistencyState "CONSISTENT"

Assert-Test "Missing RecoveryId blocked" ($noRecoveryId.Reason -eq "RECOVERY_ID_REQUIRED")

# 11
$r1 = Finalize-DeliveryRecovery `
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
    -ConsistencyState "CONSISTENT"

Assert-Test "Finalization succeeds" ($r1.Success -eq $true)

# 12
Assert-Test "Finalized status" ($r1.Status -eq "FINALIZED")

# 13
Assert-Test "Finalization reason" ($r1.Reason -eq "RECOVERY_FINALIZED")

# 14
Assert-Test "Delivery preserved" ($r1.DeliveryId -eq $DeliveryId)

# 15
Assert-Test "Execution preserved" ($r1.ExecutionId -eq $ExecutionId)

# 16
Assert-Test "Tenant preserved" ($r1.TenantId -eq $TenantId)

# 17
Assert-Test "Client preserved" ($r1.ClientId -eq $ClientId)

# 18
Assert-Test "Project preserved" ($r1.ProjectId -eq $ProjectId)

# 19
Assert-Test "Lease preserved" ($r1.LeaseId -eq $LeaseId)

# 20
Assert-Test "Recovery preserved" ($r1.RecoveryId -eq $RecoveryId)

# 21
Assert-Test "Authorization preserved" ($r1.AuthorizationId -eq $AuthorizationId)

# 22
$duplicate = Finalize-DeliveryRecovery `
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
    -ConsistencyState "CONSISTENT"

Assert-Test "Duplicate finalization blocked" ($duplicate.Status -eq "DUPLICATE")

# 23
$stored = Get-RecoveryFinalizationState
$found = $null

foreach ($entry in $stored) {
    if ($entry.FinalizationId -eq $r1.FinalizationId) {
        $found = $entry
        break
    }
}

Assert-Test "Finalization persisted" ($null -ne $found)

# 24
$loaded = Get-RecoveryFinalizationRecord -FinalizationId $r1.FinalizationId
Assert-Test "Finalization retrievable" (
    ($null -ne $loaded) -and
    ($loaded.Status -eq "FINALIZED") -and
    ($loaded.RecoveryId -eq $RecoveryId)
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-70"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"