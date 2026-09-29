$ErrorActionPreference = "Stop"
$Root = $PSScriptRoot
. "$Root\Evidence-Purge-Reuse-Guard.ps1"

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "8A-46 EVIDENCE PURGE & REUSE SECURITY GUARD" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

Reset-EvidencePurgeReuse
$results = @()

function Add-Test {
    param([string]$Name,[bool]$Passed)
    if ($Passed) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:results += [pscustomobject]@{Test=$Name;Result="PASS"}
    } else {
        Write-Host "[FAIL] $Name" -ForegroundColor Red
        $script:results += [pscustomobject]@{Test=$Name;Result="FAIL"}
    }
}

$config = Get-EvidencePurgeReuseConfig

# 01-12 configuration/security contract
Add-Test "01 purge-reuse module enabled" ($config.enabled -eq $true)
Add-Test "02 purge guard enabled" ($config.purgeGuardEnabled -eq $true)
Add-Test "03 reuse guard enabled" ($config.reuseGuardEnabled -eq $true)
Add-Test "04 fail closed enabled" ($config.failClosed -eq $true)
Add-Test "05 evidence identity required" ($config.requireEvidenceIdentity -eq $true)
Add-Test "06 retention identity required" ($config.requireRetentionIdentity -eq $true)
Add-Test "07 tenant binding required" ($config.requireTenantBinding -eq $true)
Add-Test "08 client binding required" ($config.requireClientBinding -eq $true)
Add-Test "09 project binding required" ($config.requireProjectBinding -eq $true)
Add-Test "10 execution binding required" ($config.requireExecutionBinding -eq $true)
Add-Test "11 immutable evidence required" ($config.requireImmutableEvidence -eq $true)
Add-Test "12 integrity valid required" ($config.requireIntegrityValid -eq $true)

# 13-16 command surface
Add-Test "13 purge denied by policy" ($config.denyPurge -eq $true)
Add-Test "14 reuse denied by policy" ($config.denyReuse -eq $true)
Add-Test "15 mutation denied by policy" ($config.denyMutation -eq $true)
Add-Test "16 secrets protection enabled" ($config.secretsProtectionEnabled -eq $true)

# Fixture
$fixture = Register-EvidencePurgeReuseGuard `
    -EvidenceId "EVIDENCE-8A46-001" `
    -RetentionId "RETENTION-8A46-001" `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ExecutionId "EXEC-8A46-001" `
    -EvidenceHash ("a" * 64) `
    -ImmutableEvidence $true `
    -IntegrityValid $true `
    -RetentionState "RETAINED"

$record = Find-EvidencePurgeReuseRecord -GuardId $fixture.GuardId

Add-Test "17 guard registration succeeds" ($fixture.GuardId -and $record.EvidenceId -eq "EVIDENCE-8A46-001")
Add-Test "18 purge/reuse/mutation all blocked" (
    $record.PurgeAllowed -eq $false -and
    $record.ReuseAllowed -eq $false -and
    $record.MutationAllowed -eq $false
)
Add-Test "19 decision is BLOCK" (
    $record.Decision -eq "BLOCK" -and
    $record.DecisionCode -eq "PURGE_REUSE_DENIED"
)

# 20 purge must fail closed
$purgeBlocked = $false
try {
    Invoke-EvidencePurge -GuardId $fixture.GuardId -Actor "TEST-8A46" -Reason "TEST_PURGE"
} catch {
    $purgeBlocked = $_.Exception.Message -eq "PURGE_BLOCKED"
}
Add-Test "20 purge request blocked" $purgeBlocked

# 21 reuse must fail closed
$reuseBlocked = $false
try {
    Invoke-EvidenceReuse -GuardId $fixture.GuardId -Actor "TEST-8A46" -Reason "TEST_REUSE"
} catch {
    $reuseBlocked = $_.Exception.Message -eq "REUSE_BLOCKED"
}
Add-Test "21 reuse request blocked" $reuseBlocked

# 22 mutation must fail closed
$mutationBlocked = $false
try {
    Invoke-EvidenceMutation -GuardId $fixture.GuardId -Actor "TEST-8A46" -Reason "TEST_MUTATION"
} catch {
    $mutationBlocked = $_.Exception.Message -eq "MUTATION_BLOCKED"
}
Add-Test "22 mutation request blocked" $mutationBlocked

# 23 scope + guard state
$scope23 = Test-EvidencePurgeReuseScope `
    -GuardId $fixture.GuardId `
    -TenantId "TENANT-001" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ExecutionId "EXEC-8A46-001"

$guard23 = Test-EvidencePurgeReuse -GuardId $fixture.GuardId

Add-Test "23 scope and guard validation valid" (
    $scope23.Allowed -eq $true -and
    $scope23.Code -eq "PURGE_REUSE_SCOPE_VALID" -and
    $guard23.Allowed -eq $true -and
    $guard23.Code -eq "PURGE_REUSE_GUARD_VALID"
)

# 24 integrity + cross-tenant + secrets
$scopeCross = Test-EvidencePurgeReuseScope `
    -GuardId $fixture.GuardId `
    -TenantId "TENANT-999" `
    -ClientId "CLIENT-001" `
    -ProjectId "PROJECT-001" `
    -ExecutionId "EXEC-8A46-001"

$integrity24 = Test-EvidencePurgeReuseIntegrity
$raw24 = Get-Content -LiteralPath "$Root\state\purge-reuse.json" -Raw
$secretsSafe24 = (
    $raw24 -notmatch '"RawSecret"\s*:\s*"[^"]+' -and
    $raw24 -notmatch '"RawCredential"\s*:\s*"[^"]+'
)

Add-Test "24 integrity scope denial and secrets protection valid" (
    $integrity24.Allowed -eq $true -and
    $integrity24.Code -eq "PURGE_REUSE_INTEGRITY_VALID" -and
    $scopeCross.Allowed -eq $false -and
    $scopeCross.Code -eq "CROSS_TENANT_PURGE_REUSE" -and
    $secretsSafe24
)

$total = $results.Count
$pass = @($results | Where-Object {$_.Result -eq "PASS"}).Count
$fail = @($results | Where-Object {$_.Result -eq "FAIL"}).Count

Write-Host ""
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host "TOTAL TESTS : $total" -ForegroundColor Cyan
Write-Host "RESULTAT 8A-46 : $pass PASS / $fail FAIL" -ForegroundColor Cyan
Write-Host "==============================================" -ForegroundColor Cyan
Write-Host ""

if (($total -eq 24) -and ($pass -eq 24) -and ($fail -eq 0)) {
    Write-Host "8A-46 : VALIDEE - 24/0" -ForegroundColor Green
} else {
    Write-Host "8A-46 : ECHEC - NE PAS PASSER A 8A-47" -ForegroundColor Red
}

Read-Host "Appuie sur Entrée pour fermer"
