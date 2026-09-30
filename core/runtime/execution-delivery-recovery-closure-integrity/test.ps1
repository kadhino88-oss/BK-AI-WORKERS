$ErrorActionPreference = "Stop"

$Dir = "C:\Users\FEUCOM\BK-AI-WORKERS\core\runtime\execution-delivery-recovery-closure-integrity"

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

$ClosureId       = "CLOSURE-7201"
$DeliveryId      = "DEL-7201"
$ExecutionId     = "EXE-7201"
$TenantId        = "TEN-01"
$ClientId        = "CLI-01"
$ProjectId       = "PROJ-01"
$LeaseId         = "LEASE-01"
$RecoveryId      = "REC-01"
$AuthorizationId = "AUTH-01"
$FinalizationId  = "FIN-01"
$ClosedAtUtc     = [DateTime]::UtcNow.ToString("o")

$null = Reset-ClosureIntegrity

# ============================================================
# 1
# ============================================================
$cfg = Get-ClosureIntegrityConfig

Assert-Test "Config loaded" (
    $null -ne $cfg
)

# ============================================================
# 2
# ============================================================
Assert-Test "Integrity guard enabled" (
    $cfg.integrityGuardEnabled -eq $true
)

# ============================================================
# 3
# ============================================================
Assert-Test "Reopen guard enabled" (
    $cfg.reopenGuardEnabled -eq $true
)

# ============================================================
# 4
# ============================================================
$state = @(Get-ClosureIntegrityState)

Assert-Test "Initial state empty" (
    $state.Count -eq 0
)

# ============================================================
# 5
# ============================================================
$check = Test-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc

Assert-Test "Valid closure integrity" (
    $check.Success -eq $true
)

# ============================================================
# 6
# ============================================================
Assert-Test "SHA256 generated" (
    -not [string]::IsNullOrWhiteSpace([string]$check.ClosureHash)
)

# ============================================================
# 7
# ============================================================
Assert-Test "Valid integrity status" (
    $check.Status -eq "VALID"
)

# ============================================================
# 8
# ============================================================
$missingId = Test-ClosureIntegrity `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc

Assert-Test "Missing ClosureId blocked" (
    $missingId.Reason -eq "CLOSURE_ID_REQUIRED"
)

# ============================================================
# 9
# ============================================================
$missingContext = Test-ClosureIntegrity `
    -ClosureId $ClosureId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc

Assert-Test "Incomplete context blocked" (
    $missingContext.Reason -eq "CONTEXT_INCOMPLETE"
)

# ============================================================
# 10
# ============================================================
$badStatus = Test-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "OPEN" `
    -ClosedAtUtc $ClosedAtUtc

Assert-Test "Invalid closure status blocked" (
    $badStatus.Reason -eq "CLOSURE_STATUS_INVALID"
)

# ============================================================
# 11
# ============================================================
$missingTimestamp = Test-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED"

Assert-Test "Missing timestamp blocked" (
    $missingTimestamp.Reason -eq "CLOSED_TIMESTAMP_REQUIRED"
)

# ============================================================
# 12
# ============================================================
$stored = Register-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc

Assert-Test "Integrity record registered" (
    $stored.ClosureId -eq $ClosureId
)

# ============================================================
# 13
# ============================================================
Assert-Test "Stored state CLOSED" (
    $stored.Status -eq "CLOSED"
)

# ============================================================
# 14
# ============================================================
$loaded = Get-ClosureIntegrityRecord `
    -ClosureId $ClosureId

Assert-Test "Integrity record retrievable" (
    $null -ne $loaded
)

# ============================================================
# 15
# ============================================================
Assert-Test "Stored hash preserved" (
    -not [string]::IsNullOrWhiteSpace([string]$loaded.ClosureHash)
)

# ============================================================
# 16
# ============================================================
$verify = Test-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc `
    -ExpectedHash $loaded.ClosureHash

Assert-Test "Stored integrity verifies" (
    $verify.Success -eq $true -and
    $verify.Status -eq "VALID"
)

# ============================================================
# 17
# ============================================================
$tampered = Test-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId "EXE-TAMPERED" `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc `
    -ExpectedHash $loaded.ClosureHash

Assert-Test "Tampering detected" (
    $tampered.Reason -eq "INTEGRITY_MISMATCH"
)

# ============================================================
# 18
# ============================================================
$implicitReopen = Test-ClosedClosureReopen `
    -ClosureId $ClosureId `
    -ExplicitReopen $false

Assert-Test "Implicit reopen blocked" (
    $implicitReopen.Reason -eq "IMPLICIT_REOPEN_BLOCKED"
)

# ============================================================
# 19
# ============================================================
$explicitReopen = Test-ClosedClosureReopen `
    -ClosureId $ClosureId `
    -ExplicitReopen $true

Assert-Test "Explicit reopen blocked by policy" (
    $explicitReopen.Reason -eq "EXPLICIT_REOPEN_DISABLED"
)

# ============================================================
# 20
# ============================================================
$mutation = Test-ClosedClosureMutation `
    -ClosureId $ClosureId `
    -RequestedStatus "OPEN"

Assert-Test "Closed state mutation blocked" (
    $mutation.Reason -eq "CLOSED_STATE_MUTATION_BLOCKED"
)

# ============================================================
# 21
# ============================================================
$unchanged = Test-ClosedClosureMutation `
    -ClosureId $ClosureId `
    -RequestedStatus "CLOSED"

Assert-Test "Identical CLOSED state accepted" (
    $unchanged.Success -eq $true -and
    $unchanged.Status -eq "UNCHANGED"
)

# ============================================================
# 22
# ============================================================
$duplicate = Register-ClosureIntegrity `
    -ClosureId $ClosureId `
    -DeliveryId $DeliveryId `
    -ExecutionId $ExecutionId `
    -TenantId $TenantId `
    -ClientId $ClientId `
    -ProjectId $ProjectId `
    -LeaseId $LeaseId `
    -RecoveryId $RecoveryId `
    -AuthorizationId $AuthorizationId `
    -FinalizationId $FinalizationId `
    -Status "CLOSED" `
    -ClosedAtUtc $ClosedAtUtc

Assert-Test "Duplicate integrity record blocked" (
    $duplicate.Status -eq "DUPLICATE"
)

# ============================================================
# 23
# ============================================================
$unknownReopen = Test-ClosedClosureReopen `
    -ClosureId "UNKNOWN-CLOSURE" `
    -ExplicitReopen $false

Assert-Test "Unknown closure reopen blocked" (
    $unknownReopen.Reason -eq "CLOSURE_NOT_FOUND"
)

# ============================================================
# 24 — CONTROLE FINAL
# ============================================================
$finalState = @(Get-ClosureIntegrityState)

$matching = @(
    $finalState | Where-Object {
        $_.ClosureId -eq $ClosureId
    }
)

$oneRecord = ($matching.Count -eq 1)

$finalEntry = $null

if ($oneRecord) {
    $finalEntry = $matching[0]
}

$finalChecks = $false

if ($null -ne $finalEntry) {

    $finalChecks = (
        ($finalEntry.Status -eq "CLOSED") -and
        ($finalEntry.ClosureId -eq $ClosureId) -and
        (-not [string]::IsNullOrWhiteSpace([string]$finalEntry.ClosureHash)) -and
        ([string]::Equals(
            [string]$finalEntry.ClosureHash,
            [string]$loaded.ClosureHash,
            [System.StringComparison]::OrdinalIgnoreCase
        ))
    )
}

Assert-Test "Exactly one immutable integrity record remains" (
    $oneRecord -and
    $finalChecks
)

Write-Host ""
Write-Host "=============================================="
Write-Host "RESULTATS 7H-72"
Write-Host "PASS : $Pass"
Write-Host "FAIL : $Fail"

if ($Fail -eq 0) {
    Write-Host "RESULTAT FINAL : PASS"
}
else {
    Write-Host "RESULTAT FINAL : FAIL"
}

Read-Host "Appuyez sur Entree pour fermer"