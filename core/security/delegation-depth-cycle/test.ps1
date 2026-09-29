Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'

$BasePath=$PSScriptRoot
$RuntimeFile=Join-Path $BasePath 'Delegation-Depth-Cycle.ps1'

. $RuntimeFile

$DelegationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\delegation-integrity\Delegation-Integrity.ps1'
$WorkerRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\worker-task-authority\Worker-Task-Authority.ps1'
$IdentityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\identity-auth\runtime.ps1'
$GrantRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant\Authorization-Grant.ps1'
$ExecutionRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-grant-execution\Authorization-Grant-Execution.ps1'
$GatewayRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-gateway\Authorization-Gateway.ps1'
$RBACRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\rbac\RBAC.ps1'
$FreshnessRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-freshness\Authorization-Freshness.ps1'
$IntegrityRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\authorization-context-integrity\Authorization-Context-Integrity.ps1'
$RevocationRuntime='C:\Users\FEUCOM\BK-AI-WORKERS\core\security\revocation-cascade\Revocation-Cascade.ps1'

. $DelegationRuntime
. $WorkerRuntime
. $IdentityRuntime
. $GrantRuntime
. $ExecutionRuntime
. $GatewayRuntime
. $RBACRuntime
. $FreshnessRuntime
. $IntegrityRuntime
. $RevocationRuntime

$script:Pass=0
$script:Fail=0

function Pass-Test {
    param([string]$Name)
    $script:Pass++
    Write-Host "[PASS] $Name"
}

function Fail-Test {
    param(
        [string]$Name,
        [string]$Reason=''
    )

    $script:Fail++
    Write-Host "[FAIL] $Name"

    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host "       $Reason"
    }
}

function Assert-Test {
    param(
        [bool]$Condition,
        [string]$Name,
        [string]$Reason=''
    )

    if ($Condition) {
        Pass-Test $Name
    }
    else {
        Fail-Test $Name $Reason
    }
}

# ============================================================
# RESET
# ============================================================

$null=Reset-DelegationDepthCycle
$null=Reset-DelegationIntegrity
$null=Reset-AuthorizationContextIntegrity
$null=Reset-AuthorizationFreshness
$null=Reset-RevocationCascade
$null=Reset-AuthorizationGrants
$null=Reset-GrantExecutionBindings
$null=Reset-AuthorizationGateway
$null=Reset-IdentityAuth
$null=Reset-RBAC
$null=Reset-WorkerTaskAuthority

$Tenant='8A14-TENANT'
$Client='8A14-CLIENT'
$Project='8A14-PROJECT'
$User='8A14-USER'
$Worker='LUCAS'
$Task='TASK-001'
$Action='READ'
$Execution='EXEC-8A14-001'

# ============================================================
# IDENTITY
# ============================================================

$null=New-IdentityUser `
    -UserId $User `
    -Username $User `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -AccountStatus 'ACTIVE'

$session=@(
    New-IdentitySession `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) |
    Where-Object { $_.SessionId } |
    Select-Object -Last 1

if ($null -eq $session) {
    throw 'Session setup failed.'
}

$SessionId=[string]$session.SessionId

$null=New-RBACBinding `
    -PrincipalId $User `
    -RoleId 'ROLE-OWNER' `
    -ScopeType 'TENANT' `
    -ScopeId $Tenant

$auth=@(
    Authorize-Request `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) |
    Where-Object { $_.DecisionId } |
    Select-Object -Last 1

$grant=@(
    New-AuthorizationGrant `
        -AuthorizationId $auth.DecisionId `
        -UserId $User `
        -SessionId $SessionId `
        -Action $Action `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project
) |
    Where-Object { $_.GrantId } |
    Select-Object -Last 1

$GrantId=[string]$grant.GrantId
$RawGrant=[string]$grant.Grant

$binding=New-ExecutionGrantBinding `
    -GrantId $GrantId `
    -Grant $RawGrant `
    -ExecutionId $Execution `
    -UserId $User `
    -SessionId $SessionId `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

$BindingId=[string]$binding.BindingId

$fresh=New-AuthorizationFreshness `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -Grant $RawGrant `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project

$FreshnessId=[string]$fresh.FreshnessId
$RawNonce=[string]$fresh.Nonce

$integrity=New-AuthorizationContextIntegrity `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce

$IntegrityId=[string]$integrity.IntegrityId

$authority=New-WorkerTaskAuthority `
    -UserId $User `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -WorkerId $Worker `
    -TaskId $Task `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce `
    -IntegrityId $IntegrityId

$ParentAuthorityId=[string]$authority.AuthorityId

$delegation=New-DelegationIntegrity `
    -ParentAuthorityId $ParentAuthorityId `
    -ParentWorkerId $Worker `
    -ParentTaskId $Task `
    -ChildWorkerId $Worker `
    -ChildTaskId 'TASK-CHILD-001' `
    -UserId $User `
    -TenantId $Tenant `
    -ClientId $Client `
    -ProjectId $Project `
    -SessionId $SessionId `
    -GrantId $GrantId `
    -BindingId $BindingId `
    -ExecutionId $Execution `
    -Action $Action `
    -Grant $RawGrant `
    -FreshnessId $FreshnessId `
    -Nonce $RawNonce `
    -IntegrityId $IntegrityId

if ($delegation.Success -ne $true) {
    throw "Delegation setup failed: $($delegation.Reason)"
}

$ParentDelegationId=[string]$delegation.DelegationId

# ============================================================
# 01-10 CONFIG
# ============================================================

try { Assert-Test ($null -ne (Get-DelegationDepthCycleConfig)) '01 Config loaded' }
catch { Fail-Test '01 Config loaded' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'delegationDepthCycleGuardEnabled')) '02 Depth/cycle guard enabled' }
catch { Fail-Test '02 Depth/cycle guard enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'cycleDetectionEnabled')) '03 Cycle detection enabled' }
catch { Fail-Test '03 Cycle detection enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'ancestorReuseDetectionEnabled')) '04 Ancestor reuse detection enabled' }
catch { Fail-Test '04 Ancestor reuse detection enabled' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'maxDepthEnabled')) '05 Maximum depth enabled' }
catch { Fail-Test '05 Maximum depth enabled' $_.Exception.Message }

try { Assert-Test ((Get-DelegationDepthCycleField -Name 'maxDelegationDepth') -eq 8) '06 Maximum depth set to 8' }
catch { Fail-Test '06 Maximum depth set to 8' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'requireParentDelegation')) '07 Parent delegation required' }
catch { Fail-Test '07 Parent delegation required' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'requireSameUser')) '08 Same user required' }
catch { Fail-Test '08 Same user required' $_.Exception.Message }

try { Assert-Test ([bool](Get-DelegationDepthCycleField -Name 'requireSameProject')) '09 Same project required' }
catch { Fail-Test '09 Same project required' $_.Exception.Message }

try { Assert-Test ((Get-DelegationDepthCycleField -Name 'defaultDecision') -eq 'BLOCK') '10 Default decision BLOCK' }
catch { Fail-Test '10 Default decision BLOCK' $_.Exception.Message }

# ============================================================
# 11 VALID GUARD
# ============================================================

try {
    $guard=New-DelegationDepthCycleGuard `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -Depth 1

    Assert-Test `
        ($guard.Success -eq $true -and
         $guard.Decision -eq 'ALLOW') `
        '11 Valid depth guard allowed'
}
catch {
    Fail-Test '11 Valid depth guard allowed' $_.Exception.Message
}

if ($null -eq $guard -or $guard.Success -ne $true) {
    throw 'Depth guard setup failed.'
}

$GuardId=[string]$guard.GuardId

# 12
try {
    Assert-Test `
        (-not [string]::IsNullOrWhiteSpace($GuardId)) `
        '12 Guard identifier generated'
}
catch {
    Fail-Test '12 Guard identifier generated' $_.Exception.Message
}

# 13
try {
    $record=Get-DelegationDepthCycleRecord -GuardId $GuardId

    Assert-Test `
        ($null -ne $record -and
         $record.ParentDelegationId -eq $ParentDelegationId -and
         $record.ChildDelegationId -eq 'CHILD-001' -and
         $record.Depth -eq 1) `
        '13 Delegation chain state persisted'
}
catch {
    Fail-Test '13 Delegation chain state persisted' $_.Exception.Message
}

# 14
try {
    $valid=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-002' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedDepth 2

    Assert-Test `
        ($valid.Success -eq $true -and
         $valid.Decision -eq 'ALLOW' -and
         $valid.Depth -eq 2) `
        '14 Child delegation within depth allowed'
}
catch {
    Fail-Test '14 Child delegation within depth allowed' $_.Exception.Message
}

# 15
try {
    $self=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId $ParentDelegationId `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedDepth 1

    Assert-Test `
        ($self.Success -eq $false -and
         $self.Decision -eq 'BLOCK' -and
         $self.Reason -eq 'SELF_DELEGATION_CYCLE') `
        '15 Self-cycle blocked'
}
catch {
    Fail-Test '15 Self-cycle blocked' $_.Exception.Message
}

# 16
try {
    $tooDeep=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-DEEP' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedDepth 9

    Assert-Test `
        ($tooDeep.Success -eq $false -and
         $tooDeep.Decision -eq 'BLOCK' -and
         $tooDeep.Reason -eq 'MAX_DELEGATION_DEPTH_EXCEEDED') `
        '16 Maximum delegation depth blocked'
}
catch {
    Fail-Test '16 Maximum delegation depth blocked' $_.Exception.Message
}

# 17
try {
    $duplicate=New-DelegationDepthCycleGuard `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-001' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -Depth 1

    Assert-Test `
        ($duplicate.Success -eq $false -and
         $duplicate.Decision -eq 'BLOCK' -and
         $duplicate.Reason -eq 'DUPLICATE_DELEGATION_BLOCKED') `
        '17 Duplicate parent/child delegation blocked'
}
catch {
    Fail-Test '17 Duplicate parent/child delegation blocked' $_.Exception.Message
}

# 18
try {
    $badUser=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-USER' `
        -UserId 'OTHER-USER' `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedDepth 1

    Assert-Test `
        ($badUser.Success -eq $false -and
         $badUser.Decision -eq 'BLOCK' -and
         $badUser.Reason -eq 'DELEGATION_USER_MISMATCH') `
        '18 User mismatch blocked'
}
catch {
    Fail-Test '18 User mismatch blocked' $_.Exception.Message
}

# 19
try {
    $badTenant=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-TENANT' `
        -UserId $User `
        -TenantId 'OTHER-TENANT' `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedDepth 1

    Assert-Test `
        ($badTenant.Success -eq $false -and
         $badTenant.Decision -eq 'BLOCK' -and
         $badTenant.Reason -eq 'DELEGATION_TENANT_MISMATCH') `
        '19 Tenant mismatch blocked'
}
catch {
    Fail-Test '19 Tenant mismatch blocked' $_.Exception.Message
}

# 20
try {
    $badClient=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-CLIENT' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId 'OTHER-CLIENT' `
        -ProjectId $Project `
        -RequestedDepth 1

    Assert-Test `
        ($badClient.Success -eq $false -and
         $badClient.Decision -eq 'BLOCK' -and
         $badClient.Reason -eq 'DELEGATION_CLIENT_MISMATCH') `
        '20 Client mismatch blocked'
}
catch {
    Fail-Test '20 Client mismatch blocked' $_.Exception.Message
}

# 21
try {
    $badProject=Test-DelegationDepthCycle `
        -ParentDelegationId $ParentDelegationId `
        -ChildDelegationId 'CHILD-PROJECT' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId 'OTHER-PROJECT' `
        -RequestedDepth 1

    Assert-Test `
        ($badProject.Success -eq $false -and
         $badProject.Decision -eq 'BLOCK' -and
         $badProject.Reason -eq 'DELEGATION_PROJECT_MISMATCH') `
        '21 Project mismatch blocked'
}
catch {
    Fail-Test '21 Project mismatch blocked' $_.Exception.Message
}

# 22
try {
    $unknown=Test-DelegationDepthCycle `
        -ParentDelegationId 'UNKNOWN-PARENT' `
        -ChildDelegationId 'UNKNOWN-CHILD' `
        -UserId $User `
        -TenantId $Tenant `
        -ClientId $Client `
        -ProjectId $Project `
        -RequestedDepth 1

    Assert-Test `
        ($unknown.Success -eq $false -and
         $unknown.Decision -eq 'BLOCK' -and
         $unknown.Reason -eq 'PARENT_DELEGATION_NOT_FOUND') `
        '22 Unknown parent delegation blocked'
}
catch {
    Fail-Test '22 Unknown parent delegation blocked' $_.Exception.Message
}

# 23
try {
    $invalidated=Invalidate-DelegationDepthCycleGuard `
        -GuardId $GuardId

    $state=Test-DelegationDepthCycleGuardState `
        -GuardId $GuardId

    Assert-Test `
        ($invalidated.Success -eq $true -and
         $invalidated.Status -eq 'INVALIDATED' -and
         $state.Success -eq $false -and
         $state.Decision -eq 'BLOCK') `
        '23 Invalidated guard blocked'
}
catch {
    Fail-Test '23 Invalidated guard blocked' $_.Exception.Message
}

# 24
try {
    $unknownGuard=Get-DelegationDepthCycleRecord `
        -GuardId 'DGC-NOT-FOUND'

    Assert-Test `
        ($null -eq $unknownGuard) `
        '24 Unknown guard not resolved'
}
catch {
    Fail-Test '24 Unknown guard not resolved' $_.Exception.Message
}

Write-Host ''
Write-Host '=============================================='
Write-Host 'RESULTATS 8A-14'
Write-Host ('PASS : {0}' -f $script:Pass)
Write-Host ('FAIL : {0}' -f $script:Fail)
Write-Host '=============================================='

if ($script:Pass -eq 24 -and
    $script:Fail -eq 0) {

    Write-Host 'RESULTAT FINAL : PASS'
}
else {
    Write-Host 'RESULTAT FINAL : FAIL'
}

Read-Host 'Appuyez sur Entree pour fermer'